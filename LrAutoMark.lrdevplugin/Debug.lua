--[[----------------------------------------------------------------------------
12345678901234567890123456789012345678901234567890123456789012345678901234567890

Debug 

Copyright 2010-2016, John R. Ellis -- You may use this script for any purpose, as
long as you include this notice in any versions derived in whole or part from
this file.

This module provides an interactive debugger, a prepackaged LrLogger with some
simple utility functions, and a rudimentary elapsed-time functin profiler. For
an introductory overview, see the accompanying "Debugging Toolkit.htm".

Overview of the public interface; for details, see the particular function:

namespace init ([boolean enable])
    Initializes the interactive debugger.
    
boolean enabled
    True if the interactive debugging is enabled.

void Debug.pause ()
    Pauses the plugin and displays the debugger window.

void pauseIf (boolean condition)
    Conditionally pauses the plugin and displays the debugger window.

boolean, any pcall (function, ...)
    Invokes LrTasks.pcall() in a way that's friendly for debugging.

function showErrors (function)
    Wraps a function with an error handler that invokes the debugger.

any value callWithContext (name, func, ...)
    Invokes LrFunctionContext.callWithContext() in a way that's friendly
    for debugging.

void invokeEditor (string filename, int lineNumber)
    Invokes the configured text editor on a file / line.

void showOptionsWindow ()
    Displays the debugger's Options window for setting options.

string pp (value, int indent, int maxChars, int maxLines)
    Pretty prints an arbitrary Lua value.
    
LrLogger log
    A log file that outputs to "debug.log" in the plugin directory.
    
void setLogFilename (string)    
    Changes the filename of "log".
    
void logn (...)    
    Writes the arguments to "log", converted to strings and space-separated.
    
void lognpp (...)    
    Pretty prints the arguments to "log", separated by spaces or newlines.
    
string stackTrace ()
    Returns a raw stack trace, starting at the caller.

function profileFunc (function func, string funcName)
    Enables elapsed-time profiling of a function.

string profileResults ()
    Returns the current profiling results, nicely formatted.

----------------------------------------------------------------------------
Learnings About debug.sethook ()

Hooks are specific to the coroutine/thread/LrTask.

Hooks don't survive in the function called by LrTasks.pcall(), because the
called function is actually in a different coroutine.

The only way to set a hook for all tasks is to enumerate them via
coroutine, and then set the hook for each task.
----------------------------------------------------------------------------
Learnings About Lightroom's Tasks

(Adapted from https://forums.adobe.com/thread/2245432)

LR’s “main task” cannot call a number of potentially long-running API calls
that require the ability to yield to other tasks (e.g. calls that access
the catalog).   Such calls must be made from “asynchronous tasks” created
by LrTasks.startAsynchronousTask() (or the internal equivalent).   The core
engine of the user interface appears to execute on the main task, including
plugin callbacks provided to LrView controls.  The top-level scripts of
plugins are also executed on the main task.

Lua’s built-in pcall () somehow interferes with the ability of asynchronous
tasks to yield.  If you try to call a long-running API call from within
pcall(), you’ll get the error “attempt to yield across metamethod/C-call
boundary”. (I don’t understand much about the Lua and LR implementations to
know definitely why.  But the standard implementation of Lua’s pcall() uses
C’s “longjmp” mechanism, and Lua’s coroutines may rely on longjmp as well.
LR’s tasks are layered on Lua’s coroutines, and perhaps LR’s task scheduler
relies on longmp too, and perhaps these uses of longjmp are incompatible.)

So it’s ok to use the built-in pcall() on the main task (where you can’t
call the long-running API calls in any case). And it’s also ok to use it on
asynchronous tasks, as long as you don’t invoke long-running API calls
within the pcall().

But if you need to trap errors in asynchronous tasks for code that contains
long-running API calls, you need to use LrTasks.pcall().  The documentation
says:

    Simulates Lua's standard pcall(), but in a way that allows a call to
    LrTasks.yield() to occur inside it.

It appears to “simulate” the pcall() by creating a new task to run the
called function.  The caller then waits for that task to complete.  (You
can verify that by using Lua’s built-in coroutine.running() to get the
coroutine identifiers of the caller and callee.)

The downside of the implementation of LrTasks.pcall() is that Lua’s built-
in stack tracing (debug.getinfo ()) doesn’t know how to traverse from the
callee (in one task) to the caller (in another task).  So a debugger like
Debug (and perhaps Zerobrane) will show a stack trace stopping at
LrTasks.pcall().
------------------------------------------------------------------------------]]

local Debug = {}

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrHiddenLua = nil -- import 'LrHiddenLua'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrShell = import 'LrShell'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Require
pcall (function () Require = require 'Require' end)

local bind = LrView.bind
local child = LrPathUtils.child
local compareStrings = LrStringUtils.compareStrings
local coroutine = nil -- LrHiddenLua.coroutine
local currentTime = LrDate.currentTime
local debug = debug -- LrHiddenLua.debug
local directoryEntries = LrFileUtils.directoryEntries
local exists = LrFileUtils.exists
local f = LrView.osFactory()
local getfenv = nil -- LrHiddenLua.getfenv
local getStandardFilePath = LrPathUtils.getStandardFilePath
local leafName = LrPathUtils.leafName
local lower = LrStringUtils.lower
local prefs = LrPrefs.prefsForPlugin ()
local setfenv = nil -- LrHiddenLua.setfenv
local share = LrView.share
local trimWhitespace = LrStringUtils.trimWhitespace

-- Forward references
local bindKeys, breakActive, breaksFromPrefs, breaksPush, debugHook,
    defaultTextEditor, evalDownClicked, evalPush, evalUpClicked, findFile,
    frameClicked, hidePush, importLrHiddenLua, InfoText, lineCount,
    logFilename, logPush, LrHiddenLuaText, parseError, readGlobalPrefs,
    showErrors, showWindow, sourceLines, stackDepth, stackFrames, stepPush,
    stepOverPush, stepUpPush, StringBuffer, validateExpression,
    validateSourceFile, variableClicked, viewResultPush, viewSourcePush,
    writeGlobalPrefs

local gprefs = {}
    --[[ Global preferences.  All options except breaks and stepping
    are global for all plugins and thus aren't stored in "prefs".]]

local gprefsPath =
    child (getStandardFilePath ("appData"), "debugging_toolkit.txt")
    --[[ Where the global preferences are stored. ]]

local ThisFilename = "Debug.lua"
    --[[ The name of this source file, used for filtering out stack frames of
    this module. We try to set it automatically but default to this value. ]]

Debug.DebugTerminatedError = "Debug terminated plugin execution"
    --[[ Error thrown when user hits Stop button.  Recognized by the
    function wrapper handling Debug.breakFunc. ]]

local path
    --[[ array of string: List of directories to search for the sources for
    files. ]]

local filenameLines = {}
    --[[ Mapping from filename to the file's contents, represented as an array
    of strings, one string per line. This is not updated if the user
    changes the file during a debugging session. ]]

--[[----------------------------------------------------------------------------
public namespace 
init ([boolean enable])

Re-initializes the interactive debugger.

If "enable" is true, or if it is nil and the plugin directory ends with
".lrdevplugin", or if the file "_debug.txt exists in the plugin
directory, then debugging is enabled.  Otherwise, debugging is disabled,
and calls to Debug.pause, Debug.pauseIf, Debug.breakFunc, and
Debug.unbreakFunc will be ignored.

This lets you leave calls to the debugging functions in your code and just
enable or disable the debugger via the call to Debug.init.  Further, calling
Debug.init() with no parameters automatically enables debugging only when
running from a ".lrdevplugin" directory; in released code (".lrplugin"),
debugging will be disabled.

When Debug is loaded, it does an implicit Debug.init().  That is, debugging
will be enabled if the plugin directory ends with ".lrdevplugin", disabled
otherwise.

If "_debug.txt" exists in the plugin directory, then Debug.pause() is
called (but only the first time init() is called).

Returns the Debug module.
------------------------------------------------------------------------------]]

local versionTable = LrApplication.versionTable ()

function Debug.init (enable)

        --[[ Debugging ]]
    if false then for k, _ in prefs:pairs () do prefs [k] = nil end end

    if enable == nil then
        enable = _PLUGIN.path:sub (-12) == ".lrdevplugin" or
            exists (child (_PLUGIN.path, "_debug.txt"))
        end

        --[[ If debugging is enabled, try to import LrHiddenLua, installing it
        if necessary. If that fails, disable debugging; otherwise, bring in
        the needed "hidden" items. ]]
    if enable then
        local LrHiddenLua, errorMsg = importLrHiddenLua ()
        if LrHiddenLua == nil then
            enable = false
            LrDialogs.message ("Debug couldn't properly initialize", errorMsg)
        else
            coroutine = LrHiddenLua.coroutine
            debug = LrHiddenLua.debug
            getfenv = LrHiddenLua.getfenv
            setfenv = LrHiddenLua.setfenv
            end
        end

        --[[ Figure out the filename of this file. ]]
    local function f () end
    local info = debug.getinfo (f)
    if info and info.source and info.source:sub (-4) == ".lua" then
        ThisFilename = leafName (info.source)
        end

    filenameLines = {}
    
    Debug.enabled = enable
    
        --[[ If debugging is enabled, read global debugging preferences and set
        default values for options ]]
    if enable then
        readGlobalPrefs ()

        gprefs.invokeEditor =
            (gprefs.invokeEditor == nil) and true or gprefs.invokeEditor
        gprefs.editorCommandLine =
            (gprefs.editorCommandLine ~= nil and
             gprefs.editorCommandLine ~= "") and
            gprefs.editorCommandLine or defaultTextEditor ()

        gprefs.evalAutomatically = gprefs.evalAutomatically or false
        gprefs.evalHistory = gprefs.evalHistory or {}

        gprefs.paneWidth = gprefs.paneWidth or 550
        gprefs.errorLines = gprefs.errorLines or 3
        gprefs.framesHeight = gprefs.framesHeight or 150
        gprefs.variablesHeight = gprefs.variablesHeight or 150
        gprefs.variableDetailHeight = gprefs.variableDetailHeight or 800
        gprefs.evalLines = gprefs.evalLines or 3
        gprefs.resultLines = gprefs.resultLines or 10
        gprefs.showAllFrames = gprefs.showAllFrames or false

        prefs.debugBreaks = prefs.debugBreaks or {}
        prefs.debugBreaksAndStepping = prefs.debugBreaksAndStepping == nil
            and true or prefs.debugBreaksAndStepping
        end

    return Debug
    end

--[[----------------------------------------------------------------------------
private void
readGlobalPrefs ()

Reads global preferences from "appData" into "gprefs".  If an error occurs,
it is logged but otherwise ignored.
------------------------------------------------------------------------------]]

function readGlobalPrefs ()
    local success, contents, keyValues
    gprefs = {}

    local function logError ()
        Debug.logn ("Debug couldn't read global preferences", gprefsPath,
            contents, keyValues)
        end

    success, contents = LrTasks.pcall (LrFileUtils.readFile, gprefsPath)
    if not success then
        if LrFileUtils.exists (gprefsPath) then logError () end
        return
        end
    local f = loadstring (contents)
    if f == nil then return logError () end
    success, keyValues = LrTasks.pcall (f)
    if not success then return logError () end
    gprefs = keyValues or {}
    end

--[[----------------------------------------------------------------------------
private void
writeGlobalPrefs ()

Writes the global preferences to "appData".  If an error occurs, it is
logged but otherwise ignored.
------------------------------------------------------------------------------]]

function writeGlobalPrefs ()
    local file, success, err

    local function logError ()
        if file ~= nil then file:close () end
        Debug.logn ("Debug couldn't write", gprefsPath, err)
        end

    file, err = io.open (gprefsPath, "w")
    if file == nil then return logError () end
    success, err = file:write ("return ", Debug.pp (gprefs), "\n")
    if not success then return logError () end
    success, err = file:close ()
    if not success then return logError () end
    end

--[[----------------------------------------------------------------------------
private table module, string errorMsg
importLrHiddenLua ()

Imports LrHiddenLua and returns it, with a nil "errorMsg".

If it can't be imported, then it is installed.  nil is returned for
"table", with "errorMsg" indicating whether the installation was
successful.
------------------------------------------------------------------------------]]

function importLrHiddenLua ()
    local success, LrHiddenLua = LrTasks.pcall (import, "LrHiddenLua")
    if success then return LrHiddenLua end

    local success, errorMsg, file

    local function err ()
        return nil, "Couldn't install LrHiddenLua.lrmodule: " .. errorMsg
        end

    local dir = child (child (getStandardFilePath ("appData"), "Modules"),
        "LrHiddenLua.lrmodule")
    success, errorMsg = LrTasks.pcall (LrFileUtils.createAllDirectories, dir)
    if not success then return err () end

    file, errorMsg = io.open (child (dir, "Info.lua"), "w")
    if file == nil then return err () end
    local text = InfoText:gsub ("MINOR", tostring (versionTable.minor))
        :gsub ("MAJOR", tostring (versionTable.major))
    success, errorMsg = file:write (text)
    if not success then file:close (); return err (); end
    success, errorMsg = file:close ()
    if not success then return err () end

    file, errorMsg = io.open (child (dir, "LrHiddenLua.lua"), "w")
    if file == nil then return err () end
    success, errorMsg = file:write (LrHiddenLuaText)
    if not success then file:close (); return err (); end
    success, errorMsg = file:close ()
    if not success then return err () end

    return nil, "You must restart Lightroom.\n\n" ..
        "Debugging support installed in " .. dir
    end

InfoText = [=[
--[[----------------------------------------------------------------------------
Copyright 2017 John R. Ellis.
------------------------------------------------------------------------------]]

return {
    AgToolkitIdentifier = "com.johnrellis.lrhiddenlua",
    AgExports = {LrHiddenLua = "LrHiddenLua.lua"},
    VERSION = {major = MAJOR, minor = MINOR}}
]=]

LrHiddenLuaText = [=[
--[[----------------------------------------------------------------------------
Copyright 2017 John R. Ellis

LrHiddenLua

This module provides access to built-in Lua functions and modules that
Lightroom normally hides from plugins. These are not guaranteed to work as
expected (which may be one of the reasons Adobe chose to restrict their use
in plugins).
------------------------------------------------------------------------------]]

return {
    _G = _G,
    collectgarbage = collectgarbage,
    coroutine = coroutine,
    debug = debug,
    gcinfo = gcinfo,
    getfenv = getfenv,
    module = module,
    newproxy = newproxy,
    os = os,
    package = package,
    setfenv = setfenv,
    xpcall = xpcall}
]=]

--[[----------------------------------------------------------------------------
public boolean enabled

True if debugging has been enabled by Debug.init, false otherwise.
------------------------------------------------------------------------------]]

Debug.enabled = false

--[[----------------------------------------------------------------------------
private string
defaultTextEditor ()

Returns the default text-editor command line for displaying source. See
below for a list of default editors.
------------------------------------------------------------------------------]]

local editors = {
    {WIN_ENV, [[C:\Program Files\TextPad 7\TextPad.exe]],
     '"%s" "{file}"({line})'},
    {WIN_ENV, [[C:\Program Files (x86)\TextPad 7\TextPad.exe]],
     '"%s" "{file}"({line})'},
    {WIN_ENV, [[C:\Program Files\TextPad 5\TextPad.exe]],
     '"%s" "{file}"({line})'},
    {WIN_ENV, [[C:\Program Files (x86)\TextPad 5\TextPad.exe]],
     '"%s" "{file}"({line})'},
    {WIN_ENV, [[C:\Program Files\JGSoft\EditPadPro6\EditPadPro.exe]],
     '"%s" /l{line} "{file}"'},
    {WIN_ENV, [[C:\Program Files\JGSoft\EditPadPro6\EditPadPro.exe]],
     '"%s" /l{line} "{file}"'},
    {WIN_ENV, "",
     'notepad "{file}"'},
    {MAC_ENV, [[/Applications/Sublime Text 2.app/Contents/SharedSupport/]] ..
              [[bin/subl]],
     '"%s" "{file}:{line}"'},
    {MAC_ENV, "",
     'open "{file}" -a TextEdit'}}

function defaultTextEditor ()
    for _, spec in ipairs (editors) do
        local env, path, command = spec [1], spec [2], spec [3]
        if env and (path == "" or LrFileUtils.exists (path)) then
            return string.format (command, path)
            end
        end
    assert (false, "Invalid list of editors")
    end

--[[----------------------------------------------------------------------------
public void
pause ()

Pauses the plugin and displays the debugger window if debugging is enabled.
------------------------------------------------------------------------------]]

function Debug.pause ()
    if not Debug.enabled then return end
    showWindow ("Pause", nil)
    return nil
    end

--[[----------------------------------------------------------------------------
public void
pauseIfAsked ()

Pauses the plugin and displays the debugger window if debuggng is
enabled and the file "_debug.txt" exists in the plugin directory.
------------------------------------------------------------------------------]]

function Debug.pauseIfAsked ()
    if not Debug.enabled then return end
    if not exists (child (_PLUGIN.path, "_debug.txt")) then return end
    showWindow ("Pause", nil)
    return nil
    end

--[[----------------------------------------------------------------------------
public void
pauseIf (boolean condition)

If "condition" is true and debugging is enabled, pauses the plugin and
displays the debugger window, showing all the argument values in the
Arguments pane.
------------------------------------------------------------------------------]]

function Debug.pauseIf (condition)
    if not (Debug.enabled and condition) then return end
    showWindow ("Pause", nil)
    end

--[[----------------------------------------------------------------------------
public boolean success, ...
pcall (function func, ...)

Invokes LrTasks.pcall() in a way that's friendly for debugging. It
allows Debug to trace the stack across the pcall(), and it enables the
debug hook for break points and stepping in the called function.
------------------------------------------------------------------------------]]

local calleeCaller = {}
    --[[ calleeCaller [calleeThread] maps "calleeThread", the thread created by
    LrTasks.pcall() to execute the function, to the caller thread that
    called pcall(). Used by stackFrames() to trace the stack from the
    callee thread back to the caller thread. ]]

function Debug.pcall (func, ...)

        --[[ LrTasks.pcall() cannot be called in certain contexts, such as when
        an export-service provider script is being invoked, or from a
        property table's obvserver function.  Trying to do so sometimes
        yields "attempt to yield across metamethod/C-call boundary". It
        appears that LrFunctionContext.callWithContext () makes a similar
        decision about which version of pcall() to use.  See:
        https://feedback.photoshop.com/photoshop_family/categories/photoshop_family_photoshop_lightroom ]]

    local ypcall = LrTasks.canYield () and LrTasks.pcall or pcall

    if not Debug.enabled then return ypcall (func, ...) end

    local callerThread, calleeThread = coroutine.running (), nil
    local hook, mask, count

    local function onReturn (...)
        if calleeThread ~= callerThread then
            calleeCaller [calleeThread] = nil
            end

        debug.sethook (calleeThread, hook, mask, count)

        return ...
        end

    return onReturn (ypcall (
        function (...)
            calleeThread = coroutine.running ()
            if calleeThread ~= callerThread then
                calleeCaller [calleeThread] = callerThread
                end

            hook, mask, count = debug.gethook ()
            if prefs.debugBreaksAndStepping then
                debug.sethook (debugHook, "l")
                end

            return func (...)
            end,
        ...))
    end

--[[----------------------------------------------------------------------------
public function 
showErrors (function)

Returns a function wrapped around "func" such that if any errors occur from
calling "func", the debugger window is displayed.  If debugging was disabled by
Debug.init, then instead of displaying the debugger window, the standard
Lightroom error dialog is displayed.
------------------------------------------------------------------------------]]

function Debug.showErrors (func)
    if type (func) ~= "function" then 
        error ("Debug.showErrors argument must be a function", 2)
        end

    if not Debug.enabled then return showErrors (func) end

    return function (...)
        
        local function onReturn (success, ...)
            if not success then 
                local err = select (1, ...)
                if err ~= Debug.DebugTerminatedError then 
                    showWindow ("Error", err)
                    end
                error (err, 0)
            else
                return ...
                end
            end 
        
        return onReturn (Debug.pcall (func, ...))
            end
        end

--[[----------------------------------------------------------------------------
private func
showErrors (func)

Returns a function wrapped around "func" such that if any errors occur from
calling "func", the standard Lightroom error dialog is displayed.  By
default, Lightroom doesn't show an error dialog for callbacks from LrView
controls or for tasks created by LrTasks.
------------------------------------------------------------------------------]]

function showErrors (func)
    return function (...)
        return LrFunctionContext.callWithContext("wrapped", 
            function (context)
                LrDialogs.attachErrorDialogToFunctionContext (context)
                return func (unpack (arg))
                end)
        end 
    end

--[[----------------------------------------------------------------------------
public any value
callWithContext (string name, function func, ...)

Invokes LrFunctionContext.callWithContext() in a way that's friendly for
debugging. It allows Debug to trace the stack across the call, and it
enables the debug hook for break points and stepping in the called
function.
------------------------------------------------------------------------------]]

function Debug.callWithContext (name, func, ...)
    if type (func) ~= "function" then
        error ("Debug.callWithContext argument must be a function", 2)
        end

    if not Debug.enabled then
        return LrFunctionContext.callWithContext (name, func, ...)
        end

    local callerThread, calleeThread = coroutine.running (), nil

    return LrFunctionContext.callWithContext (name, function (context, ...)
        local hook, mask, count
        calleeThread = coroutine.running ()

        if calleeThread ~= callerThread then
            calleeCaller [calleeThread] = callerThread
            end

        hook, mask, count = debug.gethook ()
        if prefs.debugBreaksAndStepping then
            debug.sethook (debugHook, "l")
            end

        context:addCleanupHandler (function ()
            if calleeThread ~= callerThread then
                calleeCaller [calleeThread] = nil
                end
            debug.sethook (calleeThread, hook, mask, count)
            end)

        return func (context, ...)
        end, ...)
    end

--[[----------------------------------------------------------------------------
private void
debugHook (string what, integer line)

This is the debug.sethook() hook function for Debug.
------------------------------------------------------------------------------]]

local breaks = {}
    --[[ array of array of {
        boolean enabled,
        string source,
        integer line,
        string conditional,
        func conditaionlFunc}

    Each user-specified break is represented by breaks [line][source].
    This layout optimizes lookup in the debugHook, which is passed just
    the line number. ]]

local breaksActive = false
    --[[ True if there is at least one enabled break in "breaks". ]]

local stepping = nil
    --[[ One of nil, "Step", "Step Over", or "Step Up", the latter
    representing an active step command issued by the user. ]]

local steppingCallerDepth = 0
    --[[ Stack depth of the caller of showWindow () when the user initiated a
    step command.   The caller is Debug.pause () or the caller of debug
    hook.  Set by showWindow (). ]]


function debugHook (what, line)

--local f = debug.getinfo (2)
--if f.source:sub (1, 1) ~= "=" then
--Debug.logn ("debugHook", line, f.source, stepping,
--    stackDepth () - 1, steppingCallerDepth, coroutine.running ())
--Debug.logn (trimWhitespace (sourceLines (f.source, f.currentline)))
--Debug.logn (Debug.stackTrace ())
--end

    if breaksActive and breaks [line] ~= nil then
        local active, conditional = breakActive (breaks, line)
        if active then
            showWindow ("Break", conditional)
            return
            end
        end

    if stepping == nil then return end

    local frame = debug.getinfo (2)
    if frame.currentline < 1 then return end
    if ThisFilename == frame.source:sub (- #ThisFilename) then return end

    if stepping == "Step" then
        showWindow ("Step", nil)

    elseif stepping == "Step Over" then
        if stackDepth () - 1 <= steppingCallerDepth then
            showWindow ("Step Over", nil)
            end

    elseif stepping == "Step Up" then
        if stackDepth () - 1 < steppingCallerDepth then
            showWindow ("Step Up", nil)
            end
    else
        assert (false, "Invalid value of 'stepping' " .. tostring (stepping))
        end
    end

--[[----------------------------------------------------------------------------
private table
breaksFromPrefs (prop)

Constructs "breaks" from the breaks stored in prefs.debugBreaks. Sets
"breaksActive" if there's at least one enabled break.
------------------------------------------------------------------------------]]

function breaksFromPrefs  (prop)
    breaks, breaksActive = {}, false

    for _, b in ipairs (prefs.debugBreaks or {}) do
        breaks [b.line] = breaks [b.line] or {}
        breaks [b.line][b.source] = {enabled = b.enabled,
            source = b.source, line = b.line, conditional = b.conditional,
            conditionalFunc = b.conditional ~= "" and
                loadstring ("return " .. b.conditional) or nil}
        breaksActive = breaksActive or b.enabled
        end
    end

--[[----------------------------------------------------------------------------
private boolean active, string conditional
breakActive (table breaks, integer line)

Returns true if there is an enabled break point whose condition evaluates
to true at line number "line" in the source file of the caller of the
caller.  (The caller of this function should be the debug hook function.)
When returning true, also returns "conditional", the break's conditional
expression, or nil if there is none.
------------------------------------------------------------------------------]]

function breakActive (breaks, line)

        --[[ See if there is an enabled breakpoint at "line" in
        the caller/caller's source. ]]
    local sources = breaks [line]
    if sources == nil then return false end
    local source = leafName (debug.getinfo (3, "S").source)
    local breakPoint = sources [source]
    if breakPoint == nil or not breakPoint.enabled then return false end
    if breakPoint.conditionalFunc == nil then return true, nil end

        --[[ Construct the environment for the condition function,
        consisting of the caller/caller's environment, the upvalues,
        and then the locals, being careful to handle nil local/up names
        correctly. ]]
    local brokenFunc = debug.getinfo (3, "f").func
    local brokenFuncEnv = getfenv (brokenFunc)
    local names, env = {}, {}

    for i = 1, math.huge do
        local name, value = debug.getupvalue (brokenFunc, i)
        if name == nil then break end
        names [name] = true
        env [name] = value
        end
    for i = 1, math.huge do
        local name, value = debug.getlocal (3, i)
        if name == nil then break end
        names [name] = true
        env [name] = value
        end

    setmetatable (env, {__index = function (t, name)
        if names [name] then
            return rawget (t, name)
        else
            return brokenFuncEnv [name]
            end
        end})

    setfenv (breakPoint.conditionalFunc, env)

        --[[ Evaluate the condition ]]
    local success, value = LrTasks.pcall (breakPoint.conditionalFunc)

        --[[ Clear the environment of the break point's condition
        function, to allow it to be GC'ed.]]
    setfenv (breakPoint.conditionalFunc, {})

    return success and value,
        breakPoint.conditional ~= "" and breakPoint.conditional or nil
    end

--[[----------------------------------------------------------------------------
private integer
stackDepth ()

Returns the number of frames on the stack, not counting this function.
Links callee threads back to caller threads using "calleeCaller".
------------------------------------------------------------------------------]]

function stackDepth ()
    local depth, thread = 0, coroutine.running ()

    while thread ~= nil do
        for i = 1, math.huge do
            if debug.getinfo (thread, i) == nil then break end
            depth = depth + 1
            end
        thread = calleeCaller [thread]
        end

    return depth - 1
    end

--[[----------------------------------------------------------------------------
private array of table
stackFrames (string errSource, integer errLine, boolean showAllFrames)

Returns the current stack as an array of frames, each frame a result of
debug.getinfo (i).

If "showAllFrames" is false, then only Lua frames with available source are
included (except for functions in this file).

Uses the "calleeCaller" table maintained by showErrors () to go from a
called thread created by showError's LrTasks.pcall() to the thread that
called LrTasks.pcall().

Additional fields are added:

localNames: array of string, the local variable names
localValues: array of any, the values corresponding to localNames
upNames: array of string, the upvalue variable names
upValues: array of any, the values corresponding to upNames

Note that the localValues and upValues arrays may contain nil values, so
#array won't necessary yield correct results (the arrays are sparse).

Any leading path is stripped from frame.source.

If non-nil "errSource" and "errLine" are the source file and line number
parsed from the current error message.  If they are different from the top
of the stack, a special frame is pushed onto the top containing them.
------------------------------------------------------------------------------]]

function stackFrames (errSource, errLine, showAllFrames)
    local frames = {}
    local thread = coroutine.running ()

    while thread ~= nil do

        for i = 1, math.huge do
            local frame = debug.getinfo (thread, i)
            if frame == nil then break end

            frame.source = leafName (frame.source)
            if showAllFrames or (frame.source:sub (1,1) ~= "=" and
               frame.source ~= ThisFilename)
            then
                frame.thread = thread
                frame.localNames, frame.localValues = {}, {}
                for l = 1, math.huge do
                    local name, value = debug.getlocal (thread, i, l)
                    if name == nil then break end
                    frame.localNames [l] = name
                    frame.localValues [l] = value
                    end

                frame.upNames, frame.upValues = {}, {}
                local func = frame.func or function () end
                for l = 1, math.huge do
                    local name, value = debug.getupvalue (func, l)
                    if name == nil then break end
                    frame.upNames [l] = name
                    frame.upValues [l] = value
                    end

                table.insert (frames, frame)
                end
            end

        thread = calleeCaller [thread]
        end

    if errSource ~= nil and (#frames == 0 or
        errSource ~= frames [1].source or errLine ~= frames [1].currentline)
    then
        table.insert (frames, 1, {source = errSource, currentline = errLine,
            localNames = {}, localValues = {}, upNames = {}, upValues = {}})
        end

    return frames
    end

--[[----------------------------------------------------------------------------
private string message, string source, integer line
parseError (string err)

Parses "err" to extract the message, source file, and line number.
Returns the reformatted string:

    message
    (source:line)

Recognizes two formats:

    compiled by require:  [string "filename.lua":line] message
    compiled by loadfile: full-file-path:line: message

Either format may optionally contain an embedded "at line n" from a
syntax error message, e.g.

    '}' expected (to close '{' at line 1032) near 'f'

In that case, the "at line" number is used.

If neither format is recognized, returns "err", nil, nil.
------------------------------------------------------------------------------]]

function parseError (err)
    local message, source, line
    source, line, message = err:match ('^.-%[string "([^"]+)"%]:(%d+): *(.*)$')
    if not source then
        source, line, message = err:match ('^.-([^\\/]+):(%d+): *(.*)$')
        end
    if source == nil then return err, nil, nil end

    local line2 = err:match ("at line (%d+)")
    if line2 ~= nil then line = line2 end

    return message .. "\n" .. "(" .. source .. ": " .. line .. ")",
        source, tonumber (line)
    end

--[[----------------------------------------------------------------------------
private void
showWindow (string who, string what)

Shows the debugger window.  "who" indicates the reason it was called:

Pause, Break, Step, Error

If "who" is Break, then "what" is the break conditional expression or ""
if there is none.

If "who" is Error, then "what" is error string.
------------------------------------------------------------------------------]]

local EvalHelpText = [[One or more expressions separated by commas, or "."
followed by one or more statements]]
EvalHelpText = EvalHelpText:gsub ("%c", " ")

local VarHelpText = [[Click a variable to view its value]]
VarHelpText = VarHelpText:gsub ("%c", " ")

function showWindow (who, what)

    --[[ Grab the stack frames here, rather than inside callWithContext(),
    which uses LrTasks.pcall() and can block tracing the stack. ]]
local err, errSource, errLine
if who == "Error" then err, errSource, errLine = parseError (what) end
local frames = stackFrames (errSource, errLine, gprefs.showAllFrames)

    --[[ Record the caller's stack depth here.  Can't do it in
    callWithContext(), since it adds different numbers of frames depending
    on whether the calling task can yield. ]]
local callerDepth = stackDepth () - 2

return LrFunctionContext.callWithContext ("", showErrors (function (context)

        --[[ Clear the stepping state; otherwise execution of Eval expressions
        could stop due to a step. ]]
    stepping = nil

    local prop = LrBinding.makePropertyTable (context)
    local result

        --[[ Repeatedly redisplay the UI as long as the user is making
        changes to the options (which may include window sizes)]]
    while true do

        --[[ Initialize prop values ]]
    prop.breaksAndStepping = prefs.debugBreaksAndStepping
    prop.evalAutomatically = gprefs.evalAutomatically

    prop.evalHistory = gprefs.evalHistory
    prop.evalHistoryI = #prop.evalHistory
    prop.evaluate = prop.evalHistory [prop.evalHistoryI] or ""

    prop.result = ""

    breaksFromPrefs (prop)
    prop.breaksActive = prefs.debugBreaksAndStepping and breaksActive

    prop.hideEnabled = LrTasks.canYield ()

        --[[ Construct the display of stack frames ]]
        --[[ Set the who and what ]]
    prop.who = who .. ":"
    prop.whoColor = nil
    prop.whoDetails = nil
    if who == "Error" then
        prop.whoColor = LrColor ("red")
        prop.whoDetails = err
        prop.whoLines = gprefs.errorLines
    elseif who == "Break" then
        prop.whoDetails = what
        prop.whoLines = 1
        end

    prop.frame = nil
    prop.selectedFrames = {}
    prop:addObserver ("selectedFrames", showErrors (function (prop, k, frames)
        prop.frame = frames ~= nil and frames [1] or nil
        return frameClicked (prop)
        end))

    prop.frameItems = {}
    for i, frame in ipairs (frames) do
        if frame.what == "C" then
            prop.frameItems [i] = {value = frame, title = "[C]"}
        elseif frame.currentline < 1 then
            prop.frameItems [i] = {value = frame, title = "[Missing source]"}
        else
            prop.frameItems [i] = {value = frame,
                title = (frame.name or "") .. " | " .. frame.source .. " " ..
                frame.currentline .. " | " ..
                trimWhitespace (sourceLines (frame.source, frame.currentline))}
            end
        end
    if #prop.frameItems > 0 then
        prop.selectedFrames = {prop.frameItems [1].value}
        end

        --[[ Variables pane ]]
    prop.variableItems = {}
    prop.selectedVariables = {}
    prop:addObserver ("selectedVariables", showErrors (function (prop, k, v)
        if v and v [1] then variableClicked (prop, v [1]) end end))

        --[[ Initiate an eval if requested ]]
    if prop.evalAutomatically then evalPush (nil, prop) end

        --[[ Construct the main window ]]
    local function action (func)
        return showErrors (function (button) func (button, prop) end)
        end

    local contents = f:column {bind_to_object = prop,
        spacing = f:label_spacing (),

        f:static_text {
            title = bind ("who"), text_color = bind ("whoColor"),
            font = "<system/bold>",},
        prop.whoDetails == nil and LrView.kIgnoredView or f:edit_field {
            height_in_lines = bind ("whoLines"), width = gprefs.paneWidth,
            wrap = true, value = bind ("whoDetails")},

        f:simple_list {height = gprefs.framesHeight, width = gprefs.paneWidth,
            items = bind ("frameItems"), value = bind ("selectedFrames")},
        f:row {
            f:push_button {title = "View Source", action = action (viewSourcePush),
                enabled = bindKeys ({"frame"}, function (v)
                    return v.frame and v.frame.currentline >= 1 end)},
            f:spacer {fill_horizontal = 1},
            f:static_text {title = VarHelpText, font = "<system/small>"},
            f:spacer {width = 20}},

        f:simple_list {height = gprefs.variablesHeight, width = gprefs.paneWidth,
            value = bind ("selectedVariables"), items = bind ("variableItems")},

        f:row {
            f:static_text {title = "Evaluate:",
                height = share ("eval")},
            f:column {height = share ("eval"),
                f:spacer {fill_vertical = 5},
                f:static_text {title = EvalHelpText, wrap = true,
                    height_in_lines = -1, font = "<system/small>"}}},

        f:row {
            f:column {fill_vertical = 1,
                f:static_text {title = "\226\136\167",
                    enabled = bindKeys ({"evalHistoryI"}, function (v)
                        return 1 < v.evalHistoryI  end),
                    mouse_down = showErrors (function ()
                        evalUpClicked (prop) end)},
                f:spacer {fill_vertical = 1},
                f:static_text {title = "\226\136\168",
                    enabled = bindKeys ({"evalHistoryI"}, function (v)
                        return v.evalHistoryI < #prop.evalHistory end),
                    mouse_down = showErrors (function ()
                        evalDownClicked (prop) end)}},
            f:edit_field {height_in_lines = gprefs.evalLines,
                width = gprefs.paneWidth, immediate = true,
                value = bind ("evaluate")}},

        f:row {
            f:push_button {title = "Eval", action = action (evalPush)},
            f:checkbox {title = "Evaluate automatically",
                    value = bind ("evalAutomatically")},
            f:spacer {fill_horizontal = 1},
            f:push_button {title = "View Result",
                action = action (viewResultPush)}},

        f:static_text {title = "Result:", font = "<system/bold>"},
        f:edit_field {value = bind ("result"),
            height_in_lines = gprefs.resultLines, width = gprefs.paneWidth},

        f:row {
            f:push_button {title = "Step", action = action (stepPush),
                enabled = bind ("breaksAndStepping")},
            f:push_button {title = "Step Over", action = action (stepOverPush),
                enabled = bind ("breaksAndStepping")},
            f:push_button {title = "Step Up", action = action (stepUpPush),
                enabled = bind ("breaksAndStepping")},
            f:push_button {title = "Breaks", action = action (breaksPush),
                enabled = bind ("breaksAndStepping")},
            f:push_button {title = "Hide for 10", action = action (hidePush),
                enabled = bind ("hideEnabled")},
            f:push_button {title = "Log", action = action (logPush)},
            f:push_button {title = "Options",
                action = showErrors (Debug.showOptionsWindow)}}}

    local accessoryView = f:static_text {bind_to_object = prop,
        title = "Breaks are active", text_color = LrColor ("red"),
        visible = bind ("breaksActive")}

    result = LrDialogs.presentModalDialog {title = "Debug",
        actionVerb = "Go", cancelVerb = "Stop",
        save_frame = "debugWindowPosition", contents = contents,
        accessoryView = accessoryView}

        --[[ Save prefs.  Save the current eval input if it isn't already saved,
        then save in prefs. ]]
    gprefs.evalAutomatically = prop.evalAutomatically
    if (prop.evaluate or "") ~= (prop.evalHistory [#prop.evalHistory] or "") then
        table.insert (prop.evalHistory, prop.evaluate)
        end
    gprefs.evalHistory = prop.evalHistory

    writeGlobalPrefs ()

    if result == "cancel" then
        error (Debug.DebugTerminatedError, 0)
    elseif result == "hide" then
        LrTasks.sleep (10)
    elseif result ~= "options" then
        break
        end
    end -- [[ End while loop for redisplaying the UI. ]]


        --[[ Set the global state controlling debugHook () ]]
    steppingCallerDepth = callerDepth

    if result == "ok" then
        stepping = nil
    elseif result == "Step" then
        stepping = "Step"
    elseif result == "Step Over" then
        stepping = "Step Over"
    elseif result == "Step Up" then
        stepping = "Step Up"
        end
    end))
    end

--[[----------------------------------------------------------------------------
LrBinding
bindKeys (array of string keys, func f, [prop])

Syntactic sugar for creating an "operation" binding on one or more keys.

    bindKeys ({"k1", ... "kn"}, function (values) ... end)

is equvalent to:

    bind {keys = {"k1", ... "kn"},
        operation = showErrors (function (binder, values, fromTable)
            if fromTable then return f (values) end
            return LrBinding.kUnsupportedDirection
            end)}

------------------------------------------------------------------------------]]

function bindKeys (keys, f, prop)
    return bind {keys = keys, bind_to_object = prop,
        operation = showErrors (function (binder, values, fromTable)
            if fromTable then return f (values) end
            return LrBinding.kUnsupportedDirection
            end)}
    end

--[[----------------------------------------------------------------------------
private void
frameClicked (prop)

Called when user clicks on a frame in the Debug window. prop.frame will be
that frame. Displays the locals and upvalues of the frame in the variables
window.  Invokes the configured text editor on the source file and line.
------------------------------------------------------------------------------]]

local lastSource, lastLine, lastTime = nil, nil, 0

function frameClicked (prop)
    local frame = prop.frame
    if frame == nil then return end

        --[[ Invoke the editor on the source.  Ignore multiple calls to
        frameClicked() for the same frame (generated on Windows.) ]]
    if gprefs.invokeEditor and frame.currentline >= 1 and
        (frame.source ~= lastSource or frame.currentline ~= lastLine or
         currentTime () - lastTime >= 1)
    then
        lastSource, lastLine = frame.source, frame.currentline
        lastTime = currentTime ()
        Debug.invokeEditor (frame.source, frame.currentline)
        end

        --[[ Construct prop.variableItems from the frame's locals and
        upvalues ]]
    local variableItems = {}
    for i, name in ipairs (frame.localNames) do
        table.insert (variableItems, {
            title = name .. " = " .. Debug.pp (frame.localValues [i], 0, 70),
            value = {name = name, value = frame.localValues [i]}})
        end

    for i, name in ipairs (frame.upNames) do
        table.insert (variableItems, {
            title = name .. " = " .. Debug.pp (frame.upValues [i], 0, 70),
            value = {name = name, value = frame.upValues [i]}})
        end

    prop.variableItems = variableItems
    end

--[[----------------------------------------------------------------------------
private void
viewSourcePush (button, prop)

Implements the View Source push button.
------------------------------------------------------------------------------]]

function viewSourcePush (button, prop)
    Debug.invokeEditor (prop.frame.source, prop.frame.currentline)
    end

--[[----------------------------------------------------------------------------
private void
variableClicked (prop, table {name = string n, value = any v} nameValue)

Called when user clicks on a variable in the Debug window. "nameValue"
contains the variable name and value.  Opens a new scrolling window to
display the full value.

Output is limited to 5000 lines.  On the Mac, edit_field () often doesn't
display the last 20 lines or so for very large outputs (e.g. 4200 lines).
------------------------------------------------------------------------------]]

function variableClicked (prop, nameValue)
    local text = nameValue.name .. " = " ..
        Debug.pp (nameValue.value, nil, nil, 5000)
    local contents = f:scrolled_view {
        width = gprefs.paneWidth, height = gprefs.variableDetailHeight,
        f:edit_field {value = text,
            height_in_lines = math.ceil (1.15 * lineCount (text, 70)),
            width = gprefs.paneWidth - (MAC_ENV and 17 or 30)}}
    LrDialogs.presentModalDialog {title = "Debug > " .. nameValue.name,
        actionVerb = "Close", cancelVerb = "< exclude >",
        save_frame = "debugVariableWindowPostion", contents = contents}
    end

--[[----------------------------------------------------------------------------
private void
stepPush (button, prop)

Implements the Step button.
------------------------------------------------------------------------------]]

function stepPush (button, mainProp)
    LrDialogs.stopModalWithResult (button, "Step")
    end

--[[----------------------------------------------------------------------------
private void
stepOverPush (button, prop)

Implements the Step button.
------------------------------------------------------------------------------]]

function stepOverPush (button, mainProp)
    LrDialogs.stopModalWithResult (button, "Step Over")
    end

--[[----------------------------------------------------------------------------
private void
stepUpPush (button, prop)

Implements the Step button.
------------------------------------------------------------------------------]]

function stepUpPush (button, mainProp)
    LrDialogs.stopModalWithResult (button, "Step Up")
    end

--[[----------------------------------------------------------------------------
private void
evalPush (button, prop)

Implements the Eval button of the debugger window. "prop" is the property table
for that window.
------------------------------------------------------------------------------]]

function evalPush (button, prop)
    local evaluate = trimWhitespace (prop.evaluate or "")
    if evaluate == "" then return end

        --[[ Save the input in the eval history ]]
    table.insert (prop.evalHistory, evaluate)
    while #prop.evalHistory > 15 do table.remove (prop.evalHistory, 1) end
    prop.evalHistoryI = #prop.evalHistory

        --[[ Compile the expression ]]
    local c = evaluate:sub (1, 1)
    if c == "." then evaluate = evaluate:sub (2) end

    local funcStr = (c == "." and "" or "return ") .. evaluate

    local f, e = loadstring (funcStr)
    if not f then
        prop.result = e
        return
        end

        --[[ Construct the environment for the expression.  We have
        to be careful to handle scoping and local/up names whose
        value is nil. ]]
    local frame, names, env = prop.frame, {}, {}
    local funcEnv = getfenv (frame.func)

    for i, name in ipairs (frame.upNames) do
        names [name] = true
        env [name] = frame.upValues [i]
        end
    for i, name in ipairs (frame.localNames) do
        names [name] = true
        env [name] = frame.localValues [i]
        end

    setmetatable (env, {
        __index = function (t, name)
            if names [name] then
                return rawget (t, name)
            else
                return funcEnv [name]
                end
            end,
        __newindex = function (t, name, value)
            if names [name] then
                rawset (t, name, value)
            else
                rawset (funcEnv, name, value)
                end
            end})

    setfenv (f, env)

        --[[ Call the function to evaluate the expression ]]
    local function callAndShow ()
        local function pack (...) return {...}, select ("#", ...) end

        prop.result = ""

        local v, n = pack (Debug.pcall (f))
            --[[ Using Debug.pcall() allows breaks in the called expression ]]
        if v [1] then
            prop.result = ""
            for i = 2, n do
                prop.result = prop.result ..
                    Debug.pp (v [i]) .. "\n"
                end
        else
            prop.result = v [2]
            end
        end

    LrTasks.startAsyncTask (showErrors (function () callAndShow () end))
    end


--[[----------------------------------------------------------------------------
private void
evalUpClicked (prop)

Called when the scroll-up text button of the eval pane is clicked.
------------------------------------------------------------------------------]]

function evalUpClicked (prop)
    prop.evalHistoryI = prop.evalHistoryI - 1
    prop.evaluate = prop.evalHistory [prop.evalHistoryI]
    end

--[[----------------------------------------------------------------------------
private void
evalDownClicked (prop)

Called when the scroll-up text button of the eval pane is clicked.
------------------------------------------------------------------------------]]

function evalDownClicked (prop)
    prop.evalHistoryI = prop.evalHistoryI + 1
    prop.evaluate = prop.evalHistory [prop.evalHistoryI]
    end

--[[----------------------------------------------------------------------------
private void
viewResultPush (button, prop)

Implements the View Result button.

Output is limited to 5000 lines.  On the Mac, edit_field () often doesn't
display the last 20 lines or so for very large outputs (e.g. 4200 lines).
------------------------------------------------------------------------------]]

function viewResultPush (button, prop)
    local contents = f:scrolled_view {
        width = gprefs.paneWidth, height = gprefs.variableDetailHeight,
        f:edit_field {value = prop.result,
            height_in_lines = math.ceil (1.15 * lineCount (prop.result, 70)),
            width = gprefs.paneWidth - (MAC_ENV and 17 or 30)}}
    LrDialogs.presentModalDialog {title = "Debug > Result",
        actionVerb = "Close", cancelVerb = "< exclude >",
        save_frame = "debugVariableWindowPostion", contents = contents}
    end

--[[----------------------------------------------------------------------------
private void
logPush (button, prop)

Implements the "Log" button of the debugger window.  "prop" is the property
table for that window.
------------------------------------------------------------------------------]]

function logPush (button, prop)
    Debug.invokeEditor (logFilename, 1000000)
    end

--[[----------------------------------------------------------------------------
private void
hidePush (button, prop)

Implements the "Hide for 10" button of the debugger window.  "prop" is the
property table for that window.
------------------------------------------------------------------------------]]

function hidePush (button, prop)
    LrDialogs.stopModalWithResult (button, "hide")
    end

--[[----------------------------------------------------------------------------
private void
breaksPush (button, prop)

Implements the "Breaks" button of the debugger window.  "prop" is the
property table for that window.
------------------------------------------------------------------------------]]

local MaxBreakPoints = 20

function breaksPush (button, prop)

        --[[ Construct in "sources" the list of available .lua files ]]
    local sourceSet = {}
    for _, pathDir in ipairs (Require.pathDirectories ()) do
        for filename in directoryEntries (pathDir) do
            if lower (filename:sub (-4)) == ".lua" then
                sourceSet [leafName (filename)] = true
                end
            end
        end

    local sources = {}
    for source, _ in pairs (sourceSet) do table.insert (sources, source) end
    table.sort (sources, LrStringUtils.compareStrings)

        --[[ Construct the dialog controls ]]
    local rows = {f:row {
        f:static_text {title = "Enabled:", width = share ("enabled")},
        f:static_text {title = "Source file:", width = share ("source")},
        f:static_text {title = "Line:", width = share ("line")},
        f:static_text {title = "Conditional expression:",
            width = share ("conditional")}}}

    local conditionals = {}
    for i = 1, MaxBreakPoints do
        table.insert (rows, f:row {
            f:row {width = share ("enabled"),
                f:spacer {fill = 1},
                f:checkbox {value = bind ("enabled" .. i)},
                f:spacer {fill = 1}},
            f:combo_box {value = bind ("source" .. i),
                width_in_chars = 20, width = share ("source"),
                immediate = true,
                items = sources, validate = showErrors (validateSourceFile)},
            f:edit_field {value = bind ("line" .. i), min = 1, max = math.huge,
                precision = 0, width_in_digits = 5, width = share ("line")},
            f:edit_field {value = bind ("conditional" .. i),
                width_in_chars = 35, width = share ("conditional"),
                immediate = true,
                validate = showErrors (validateExpression)}})
        table.insert (conditionals, "conditional" .. i)
        end

    for i = 1, MaxBreakPoints do
        prop ["enabled" .. i] = true
        prop ["source" .. i] = ""
        prop ["line" .. i] = 1
        prop ["conditional" ..i] = ""
        end

    for i, row in ipairs (prefs.debugBreaks) do
        prop ["enabled" .. i] = row.enabled
        prop ["source" .. i] = row.source
        prop ["line" .. i] = row.line
        prop ["conditional" ..i] = row.conditional
        end

    local function allConditionalsValid (values)
        for i = 1, #conditionals do
            local valid = validateExpression (nil, values [conditionals [i]])
            if not valid then return false end
            end
        return true
        end

    local contents = f:column {bind_to_object = prop,
        spacing = f:control_spacing (),
        f:column (rows)}

            --[[ Show the dialog ]]
    local result = LrDialogs.presentModalDialog {
        title = "Debug > Breakpoints", contents = contents,
        actionBinding = {enabled = {bind_to_object = prop,
            keys = conditionals,
            operation = showErrors (function (binder, values, fromTable)
                if fromTable then return allConditionalsValid (values) end
                return LrBinding.kUnsupportedDirection
                end),
            transform = showErrors (function (value, fromTable)
                return value
                end)}}}

    if result == "cancel" then return end

        --[[ Save away in "breaks" and "prefs"]]
    local prefsBreaks = {}
    for i = 1, MaxBreakPoints do
        local enabled, source, line, conditional =
            prop ["enabled" .. i], trimWhitespace (prop ["source" .. i]),
            prop ["line" .. i], trimWhitespace (prop ["conditional" .. i])
        if source ~= "" then
            table.insert (prefsBreaks, {enabled = enabled,
                source = source, line = line, conditional = conditional})
            end
        end

    prefs.debugBreaks = prefsBreaks
    breaksFromPrefs (prop)
    prop.breaksActive = breaksActive
    end


--[[----------------------------------------------------------------------------
private boolean, value
validateSourceFile (view, value)

The validate function for the Source File edit boxes.  Returns true, value
if "value" is a filename existing on Require's search path; returns false,
value otherwise.
------------------------------------------------------------------------------]]

function validateSourceFile (view, value)
    return Require.findFile (value) and true or false, value
    end

--[[----------------------------------------------------------------------------
private boolean, value
validateExpression (view, value)

The validate function for the Conditional Expression edit boxes.  Returns
true, value if "value" is a syntactically correct Lua expression; returns
false, value otherwise.
------------------------------------------------------------------------------]]

function validateExpression (view, value)
    value = trimWhitespace (value or "")
    return value == "" or
            (loadstring ("return " .. value) and true or false),
        value
    end

--[[----------------------------------------------------------------------------
public void
showOptionsWindow (button)

Displays the Debugger Options window.
------------------------------------------------------------------------------]]

local EditorText = [[Command line for a text editor invoked by Debug to
display a source location; the tokens {file} and {line} will get replaced
by the full file path and line number of the file Debug is displaying. Be
sure to put double quotes around the program path and the {file} token.]]
EditorText = EditorText:gsub ("%c", " ")

local InvokeText = [[Automatically invoke the editor whenever a stack frame
is selected]]
InvokeText = InvokeText:gsub ("%c", " ")

local BreakText = [[To enable break points and stepping, enable
the following option and restart the plugin. It will slow down the
plugin's execution by about 7x (but not Lightroom itself).]]
BreakText = BreakText:gsub ("%c", " ")

local WindowSizeText = [[Unfortunately, limitations of the SDK prevent some
UI controls in the Debug window from automatically resizing. So specify
your desired sizes here:]]
WindowSizeText = WindowSizeText:gsub ("%c", " ")

function Debug.showOptionsWindow (button)
return LrFunctionContext.callWithContext ("", function (context)

    local prop = LrBinding.makePropertyTable (context)
    prop.editorCommandLine = gprefs.editorCommandLine
    prop.invokeEditor = gprefs.invokeEditor
    prop.breaksAndStepping = prefs.debugBreaksAndStepping
    prop.paneWidth = gprefs.paneWidth
    prop.errorLines = gprefs.errorLines
    prop.framesHeight = gprefs.framesHeight
    prop.variablesHeight = gprefs.variablesHeight
    prop.variableDetailHeight = gprefs.variableDetailHeight
    prop.evalLines = gprefs.evalLines
    prop.resultLines = gprefs.resultLines
    prop.showAllFrames = gprefs.showAllFrames

    local contents = f:column {
        bind_to_object = prop,
        spacing = f:control_spacing (),

        f:group_box {title = "Editor",
            f:static_text {title = EditorText, width_in_chars = 50, wrap = true,
                height_in_lines = -1},
            f:edit_field {value = bind ("editorCommandLine"), immediate = true,
                width_in_chars = 50},
            f:checkbox {value = bind ("invokeEditor"), title = InvokeText,
                width_in_chars = 50, wrap = true}},

        f:group_box {title = "Breaks and Stepping",
            f:static_text {title = BreakText, width_in_chars = 50, wrap = true,
                height_in_lines = -1},
            f:checkbox {title = "Enable breaks and stepping", wrap = true,
                height_in_lines = -1, width_in_chars = 50,
                value = bind ("breaksAndStepping")}},

        f:group_box {title = "Window Sizes",
            f:static_text {title = WindowSizeText, width_in_chars = 50,
                wrap = true, height_in_lines = -1},
            f:row {
                f:column {
                    f:row {
                        f:static_text {title = "Debug window:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("paneWidth"), min = 450,
                            max = 2000, precision = 0, width_in_digits = 4},
                        f:static_text {title = "pixels wide"}},
                    f:row {
                        f:static_text {title = "Error text:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("errorLines"), min = 1,
                            max = 50, precision = 0, width_in_digits = 4},
                        f:static_text {title = "lines"}},
                    f:row {
                        f:static_text {title = "Stack frames:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("framesHeight"), min = 80,
                            max = 500, precision = 0, width_in_digits = 4},
                        f:static_text {title = "pixels tall"}},
                    f:row {
                        f:static_text {title = "Variables:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("variablesHeight"),
                            min = 80, max = 500, precision = 0,
                            width_in_digits = 4},
                        f:static_text {title = "pixels tall"}}},
                f:column {
                    f:row {
                        f:static_text {title = "Eval text:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("evalLines"), min = 1,
                            max = 50, precision = 0, width_in_digits = 4},
                        f:static_text {title = "lines"}},
                    f:row {
                        f:static_text {title = "Result text:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("resultLines"), min = 1,
                            max = 50, precision = 0, width_in_digits = 4},
                        f:static_text {title = "lines"}},
                    f:row {
                        f:static_text {title = "View result:",
                            alignment = "right", width = share ("l")},
                        f:edit_field {value = bind ("variableDetailHeight"),
                            min = 80, max = 2000, precision = 0,
                            width_in_digits = 4},
                        f:static_text {title = "pixels tall"}}}}},

        f:group_box {title = "Stack Frames",
            f:checkbox {title = "Show internal Lightroom and C stack frames",
                value = bind ("showAllFrames")}}}

    local result = LrDialogs.presentModalDialog {title = "Debug > Options",
        contents = contents}
    if result == "cancel" then return end

    gprefs.editorCommandLine = prop.editorCommandLine
    gprefs.invokeEditor = prop.invokeEditor
    prefs.debugBreaksAndStepping = prop.breaksAndStepping
    gprefs.paneWidth = prop.paneWidth
    gprefs.errorLines = prop.errorLines
    gprefs.framesHeight = prop.framesHeight
    gprefs.variablesHeight = prop.variablesHeight
    gprefs.variableDetailHeight = prop.variableDetailHeight
    gprefs.evalLines = prop.evalLines
    gprefs.resultLines = prop.resultLines
    gprefs.showAllFrames = prop.showAllFrames

    writeGlobalPrefs ()
        --[[ Write the global preferences here, because this window could
        also be invoked from debugscript.  The options are also written
        when the main showWindow() dialog exits. ]]

    LrDialogs.stopModalWithResult (button, "options")
    end)
    end


--[[----------------------------------------------------------------------------
public void
invokeEditor (string filename, int lineNumber)

If the user has configured a text editor, it is invoked on "filename" /
"lineNumber".  If "filename" is a relative file, it is resolved to a qualified
file path using findFile(). Any failures are silently ignored.
------------------------------------------------------------------------------]]

function Debug.invokeEditor (filename, lineNumber)
    if not gprefs.editorCommandLine then return end
    if not lineNumber then lineNumber = 1 end
    filename = findFile (filename) or filename

    LrFunctionContext.postAsyncTaskWithContext ("", function (context)
        LrDialogs.attachErrorDialogToFunctionContext (context)
        local cmd = gprefs.editorCommandLine:gsub ("{file}", filename)
        cmd = cmd:gsub ("{line}", lineNumber)
        if WIN_ENV then cmd = '"' .. cmd .. '"' end
        LrTasks.execute (cmd)
        end)
    end


--[[----------------------------------------------------------------------------
private string
findFile (string filename)

Returns a fully qualified file path for the .lua source file "filename". If
"filename" is absolute, it is returned.  If a directory path has been set with
Debug.path, the file is searched for there; otherwise, if Require has been
loaded, then Require.findFile is called to find the file; otherwise,
_PLUGIN.path is searched.  Returns nil if the file can't be found.

If the first character of "filename" is "@", it is ignored.  (dofile () appears
to put it there -- not sure why.)
------------------------------------------------------------------------------]]

function findFile (filename)
    if filename:sub (1, 1) == "@" then filename = filename:sub (2) end
    if not LrPathUtils.isRelative (filename) then return filename end
    if not path and Require then return Require.findFile (filename) end

    for i, dir in ipairs (path or {_PLUGIN.path}) do
        if LrPathUtils.isRelative (dir) then
            dir = LrPathUtils.child (_PLUGIN.path, dir)
            end
        local filePath = LrPathUtils.child (dir, filename)
        if LrFileUtils.exists (filePath) then return filePath end
        end
    return nil
    end

--[[----------------------------------------------------------------------------
private string
sourceLines (string filename, int lineNumber [, int n])

Returns up to "n" source lines from file "filename", starting at line number
"lineNumber".  "filename" is resolved via findFile().  "n" defaults to 1.
Returns "" if the file can't be read for any reason.
------------------------------------------------------------------------------]]

function sourceLines (filename, lineNumber, n)
    if not n then n = 1 end
    if filename:sub (1, 1) == "=" then
        return ""
        end

    if not filenameLines [filename] then
        local lines = {}
        local f = io.open (findFile (filename) or filename, "r")
        if f then
            while true do
                local line = f:read ("*l")
                if not line then break end
                table.insert (lines, line)
                end
            f:close ()
            end
        filenameLines [filename] = lines
        end

    local lines = ""
    for i = lineNumber, lineNumber + n - 1 do
        if i > lineNumber then lines = lines .. "\n" end
        lines = lines .. (filenameLines [filename][i] or "")
        end
    return lines
    end


--[[----------------------------------------------------------------------------
private boolean
isSDKObject (x)

Returns true if "x" is an object implemented by the LR SDK. In LR 3, those
objects are tables with a string for a metatable, but in LR 4 beta,
getmetatable() raises an error for such objects.

NOTE: This is also in Util.lua.
------------------------------------------------------------------------------]]

local majorVersion = LrApplication.versionTable ().major

local function isSDKObject (x)
    if type (x) ~= "table" then
        return false
    elseif majorVersion < 4 then
        return type (getmetatable (x)) == "string"
    else
        local success, value = pcall (getmetatable, x)
        return not success or type (value) == "string"
    end
end


--[[----------------------------------------------------------------------------
public string
pp (value, int indent, int maxChars, int maxLines)

Returns "value" pretty printed into a string.  The string is guaranteed not
to end in a newline.

indent (default 4): If "indent" is greater than zero, then it is the number
of characters to use for indenting each level.  If "indent" is 0, then the
value is pretty-printed all on one line with no newlines.

maxChars (default maxLines * 100): The output is guaranteed to be no longer
than this number of characters.  If it exceeds maxChars - 3, then the last
three characters will be "..." to indicate truncation.

maxLines (default 5000): The output is guaranteed to have no more than this
many lines. If it is truncated, the last line will end with "..."
------------------------------------------------------------------------------]]

function Debug.pp (value, indent, maxChars, maxLines)
    if not indent then indent = 4 end
    if not maxLines then maxLines = 5000 end
    if not maxChars then maxChars = maxLines * 100 end
    
    local s = StringBuffer:new ()
    local lines = 1
    local tableLabel = {}
    local nTables = 0    

    local function addNewline (i)
        if s:length () >= maxChars or lines >= maxLines then return true end
        if indent > 0 then
            s:cat ("\n"):cat (string.rep (" ", i))
            lines = lines + 1
            end
        return false
        end

    local function pp1 (x, i)
        if type (x) == "string" then
            s:cat (string.format ("%q", x))
            
        elseif type (x) ~= "table" then
            s:cat (tostring (x))
            
        elseif isSDKObject (x) then
            s:cat (tostring (x))
            
        else
            if tableLabel [x] then
                s:cat (tableLabel [x])
                return false
                end
            
            local isEmpty = true
            for k, v in pairs (x) do isEmpty = false; break end
            if isEmpty then 
                s:cat ("{}")
                return false
                end

            nTables = nTables + 1
            local label = "table: " .. nTables
            tableLabel [x] = label

            local first = true
            local function ppKV (k, v)
                if first then
                    first = false
                else
                    s:cat (", ")
                    end
                if addNewline (i + indent) then return true end 
                if type (k) == "string" and k:match ("^[_%a][_%w]*$") then
                    s:cat (k)
                else 
                    s:cat ("[")
                    if pp1 (k, i + indent) then return true end
                    s:cat ("]")
                    end
                s:cat (" = ")
                if pp1 (v, i + indent) then return true end
                end

            s:cat ("{")
            if indent > 0 then s:cat ("--"):cat (label) end
            x = table.shallowcopy (x)

                --[[ Print all string keys in sorted order and remove them ]]
            local keys = {}
            for k, _ in pairs (x) do
                if type (k) == "string" then table.insert (keys, k) end
                end
            table.sort (keys, compareStrings)

            for _, k in ipairs (keys) do
                if ppKV (k, x [k]) then return true end
                x [k] = nil
                end

                --[[ Print all non-numeric keys and remove them ]]
            for k, v in pairs (x) do
                if type (k) ~= "number" then
                    if ppKV (k, v) then return true end
                    x [k] = nil
                    end
                end

                --[[ Print numeric keys in order, removing them. Note that
                the indices may be sparse, so we can't use "for i =". ]]
            local keys = {}
            for k, v in pairs (x) do
                assert (type (k) == "number", type (k))
                table.insert (keys, k)
                end
            table.sort (keys)

            for _, k in ipairs (keys) do
                if ppKV (k, x [k]) then return true end
                end

            s: cat("}")
            end

        return false
        end
    
    local truncated = pp1 (value, 0)
    local str = s:toStr ()
    if truncated or #str > maxChars then
        str = str:sub (1, math.max (0, maxChars - 3)) .. "..."
        end
    return str
    end

--[[----------------------------------------------------------------------------
private StringBuffer

A StringBuffer provides a much faster way to do a large number of string
concatenations on strings several thousands characters and more.
------------------------------------------------------------------------------]]

StringBuffer = {}
StringBuffer.__index = StringBuffer

--[[----------------------------------------------------------------------------
stringBuffer
StringBuffer:new ()
------------------------------------------------------------------------------]]

function StringBuffer:new ()
    local sb = {}
    setmetatable (sb, self)
    sb.len = 0
    return sb
    end

--[[----------------------------------------------------------------------------
stringBuffer
StringBuffer:toStr (string s)
------------------------------------------------------------------------------]]

function StringBuffer:toStr ()
    return table.concat (self)
    end

--[[----------------------------------------------------------------------------
stringBuffer
StringBuffer:cat (string s)
------------------------------------------------------------------------------]]

function StringBuffer:cat (s)
    table.insert (self, s)
    self.len = self.len + #s
    return self
    end


--[[----------------------------------------------------------------------------
stringBuffer
StringBuffer:length ()
------------------------------------------------------------------------------]]

function StringBuffer:length ()
    return self.len
    end
        
--[[----------------------------------------------------------------------------
public LrLogger log

The "log" is an LrLogger log file that by default writes to the file "debug.log"
in the current plugin directory.
------------------------------------------------------------------------------]]

Debug.log = LrLogger (_PLUGIN.id)
    --[[ This apparently must be unique across all of Lightroom and plugins.]]

logFilename = LrPathUtils.child (_PLUGIN.path, "debug.log")

Debug.log:enable (function (msg)
    local f = io.open (logFilename, "a")
    if f == nil then return end
    f:write (
        LrDate.timeToUserFormat (currentTime (), "%y/%m/%d %H:%M:%S "),
        msg, "\n")
    f:close ()
    end)
    

--[[----------------------------------------------------------------------------
public void
setLogFilename (string)

Sets the filename of the log to be something other than the default
(_PLUGIN.path/debug.log).
------------------------------------------------------------------------------]]

function Debug.setLogFilename (filename)
    logFilename = filename
    end


--[[----------------------------------------------------------------------------
public void
logn (...)

Writes all of the arguments to the log, separated by spaces on a single line,
using tostring() to convert to a string.  Useful for low-level debugging.
------------------------------------------------------------------------------]]

function Debug.logn (...)
    local s = ""
    for i = 1, select ("#", ...) do
        local v = select (i, ...)
        s = s .. (i > 1 and " " or "") .. tostring (v) 
        end
    Debug.log:trace (s)
    end

--[[----------------------------------------------------------------------------
public void
lognpp (...)

Pretty prints all of the arguments to the log, separated by spaces or newlines.  Useful
------------------------------------------------------------------------------]]

function Debug.lognpp (...)
    local s = ""
    local sep = " "
    for i = 1, select ("#", ...) do
        local v = select (i, ...)
        local pp = Debug.pp (v)
        s = s .. (i > 1 and sep or "") .. pp
        if lineCount (pp) > 1 then sep = "\n" end
        end
    Debug.log:trace (s)
    end

--[[----------------------------------------------------------------------------
private int
lineCount (string s [, integer lineWidth])

Counts the number of lines in "s".  The last line may or may not end
with a newline, but it counts as a line.  Lines that are longer
than "lineWidth" will be considered to have wrapped and count
as multiple lines.   "lineWidth" defaults to math.huge.
------------------------------------------------------------------------------]]

function lineCount (s, lineWidth)
    if lineWidth == nil then lineWidth = math.huge end

    local function ceil (nChars, lineWidth)
        return math.max (1, math.ceil (nChars / lineWidth))
        end

    local nLines, nChars = 0, 0
    for i = 1, #s do
        if s:sub (i, i) ~= "\n" then
            nChars = nChars + 1
        else
            nLines = nLines + ceil (nChars, lineWidth)
            nChars = 0
            end
        end

    if #s > 0 and s:sub (-1, -1) ~= "\n" then
        nLines = nLines + ceil (nChars, lineWidth)
        end
    return nLines
    end

--[[----------------------------------------------------------------------------
public string
stackTrace ()

Returns a raw stack trace (starting with the caller), one frame per line.
Similar to debug.traceback(), except that it traces through
Debug.showErrors() and LrTasks.pcall().
------------------------------------------------------------------------------]]

function Debug.stackTrace ()
    local s = "Stack trace:"

    local thread, i = coroutine.running (), 2
    while thread ~= nil do

    while true do
        local info = debug.getinfo (i)
        if not info then break end
            s = string.format ("%s\n%s | %s %s]", s, info.name or "",
                info.source or "", info.currentline)
        i = i + 1
        end

        thread = calleeCaller [thread]
        i = 1
    end

    return s
    end

--[[----------------------------------------------------------------------------
public function
profileFunc (function func, string funcName)

Returns "func" wrapped with simple profiling, recording the total time used, the
total number of calls, and the number of top-level (non-recursive) calls.

Usage:

    myFunc1 = Debug.profileFunc (myFunc1, "myFunc1")
    myFunc2 = Debug.profileFunc (myFunc2, "myFunc2")
    ...
    ...run the code to be profile...
    logn (Debug.profileResults ()) -- record the results to the log

Limitation:

- A call to a function that occurs in thread B while another call to the same
function is active in thread A will be treated as a recursive (non-top-level)
call.  There doesn't appear to be any efficient way of identifying the
current task.
------------------------------------------------------------------------------]]

local funcNameResult = {}

function Debug.profileFunc (func, funcName)
    local nCalls, nTopCalls, totalTime = 0, 0, 0
    local active = false

    local function results ()
        return {funcName = funcName, nCalls = nCalls, nTopCalls = nTopCalls,
                totalTime = totalTime}
        end

    local function wrapped (...)
        local t
        nCalls = nCalls + 1

        local function recordResults (success, ...)
            totalTime = totalTime + (currentTime () - t)
            active = false
            if success then
                return ...
            else
                error (select (1, ...), 0)
                end
            end

        if not active then
            active = true
            nTopCalls = nTopCalls + 1
            t = currentTime ()
            if LrTasks.canYield () then
                return recordResults (LrTasks.pcall (func, ...))
            else
                return recordResults (pcall (func, ...))
                end
        else
            return func (...)
            end
        end

    funcNameResult [funcName] = results
    return wrapped
    end

--[[----------------------------------------------------------------------------
public string
profileResults ()

Returns the profiling results of profiled functions, nicely formatted.
------------------------------------------------------------------------------]]

function Debug.profileResults ()
    local s = ""
    s = s .. string.format ("\n%-25s %10s %10s %10s %10s %10s", "Function",
        "calls", "top calls", "time", "time/call", "time/top")
    for funcName, results in pairs (funcNameResult) do
        local r = results ()
        s = s .. string.format ("\n%-25s %10d %10d %10.5f %10.5f %10.5f",
            funcName, r.nCalls, r.nTopCalls, r.totalTime,
            r.nCalls > 0 and r.totalTime / r.nCalls or 0.0,
            r.nTopCalls > 0 and r.totalTime / r.nTopCalls or 0.0)
        end
    return s
    end

--[[----------------------------------------------------------------------------
------------------------------------------------------------------------------]]

Debug.init ()

return Debug