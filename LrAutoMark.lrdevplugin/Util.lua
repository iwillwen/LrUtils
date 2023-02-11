--[[----------------------------------------------------------------------------
12345678901234567890123456789012345678901234567890123456789012345678901234567890

Utilities for Plugins

local Util = require 'Util'

Miscellaneous functions and variables.
------------------------------------------------------------------------------]]

local Util = {}

require "strict"

local LrApplication = import "LrApplication"
local LrBinding = import "LrBinding"
local LrDate = import "LrDate"
local LrDialogs = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrPrefs = import "LrPrefs"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrUUID = import "LrUUID"
local LrView = import "LrView"

local Debug = require "Debug"

local catalog = LrApplication.activeCatalog ()
local child = LrPathUtils.child
local chooseUniqueFileName = LrFileUtils.chooseUniqueFileName
local currentTime = LrDate.currentTime
local fileAttributes = LrFileUtils.fileAttributes
local floor = math.floor
local format = string.format
local generateUUID = LrUUID.generateUUID
local getStandardFilePath = LrPathUtils.getStandardFilePath
local leafName = LrPathUtils.leafName
local pcall = LrTasks.pcall
local parent = LrPathUtils.parent
local prefs = import 'LrPrefs'.prefsForPlugin ()
local showErrors = Debug.showErrors

    -- Forward reference
local withAccessDo

--[[----------------------------------------------------------------------------
public string Newline

A platform-indepent newline. Unfortunately, some controls (e.g. edit_field) need
to have the old-fashioned \r\n supplied in strings to display newlines properly
on Windows.  
------------------------------------------------------------------------------]]

Util.Newline = WIN_ENV and "\r\n" or "\n"


--[[----------------------------------------------------------------------------
public boolean
isSDKObject (x)

Returns true if "x" is an object implemented by the LR SDK. In LR 3, those
objects are tables with a string for a metatable, but in LR 4 beta,
getmetatable() raises an error for such objects.  

NOTE: This is also in Debug.lua.
------------------------------------------------------------------------------]]

local majorVersion = LrApplication.versionTable ().major

function Util.isSDKObject (x)
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
public function (function block)
newGuard ()

The result "g" is a recursion guard.  g (block) will invoke block() and
return its result.  While block () is executing, any attempt to enter the
guard again by calling g (block1) will just return nil without invoking
block1().   Example:

    local g = Util.newGuard ()
    ...
    g (function ()
        ...stuff to do...
        end)

This is similar to LrRecursionGuard, except syntactically more conside,
perhaps lighter weight and doesn't have issues with being called in
LrDevelopController notifier context.
------------------------------------------------------------------------------]]

function Util.newGuard ()
    local inGuard = false
    return function (f)
        if inGuard then return end
        LrFunctionContext.callWithContext ("g", showErrors (function (context)
            context:addCleanupHandler (function () inGuard = false end)
            inGuard = true
            f ()
            end))
        end
    end

--[[----------------------------------------------------------------------------
public number
round (number x [, number d])

Rounds x to the number of digits d.  If d == 0, rounds to the nearest 
integer.  If d > 0, rounds to the dth position to the left of the decimal
point. If d < 0, rounds to the dth position to the right of the decimal.
If d is nil, defaults to 0.
------------------------------------------------------------------------------]]

function Util.round (x, d)
    if d == nil or d == 0 then 
        return x >= 0 and math.floor (x + 0.5) or math.ceil (x - 0.5)
    else
        return Util.round (x * 10 ^ -d) / 10 ^ -d
        end
    end

--[[----------------------------------------------------------------------------
public array 
arrayMap (array t, func)

Applies "func" to each element of "t" and returns the array of results:

    {func (t [0]), func (t [1]), ...}
------------------------------------------------------------------------------]]

function Util.arrayMap (t, func)
    local result = {}
    for k, v in ipairs (t) do table.insert (result, func (v)) end
    return result
    end
        
--[[----------------------------------------------------------------------------
public value 
arrayReduce (array t, initialValue, func)

Applies "func" to combine all the elements of "t":

    func (func (func (initialValue, t [0]), t [1]), ...
    
If "t" is empty, returns "initialValue".    
------------------------------------------------------------------------------]]

function Util.arrayReduce (t, initialValue, func)
    local result = initialValue
    for k, v in ipairs (t) do result = func (result, v) end
    return result
    end
        
--[[----------------------------------------------------------------------------
public 
array arrayFilter (array t, func)

Return as an array the elements of array "t", t [i], for which func (t [i]) is
true.
------------------------------------------------------------------------------]]

function Util.arrayFilter (t, func)
    local result = {}
    for k, v in ipairs (t) do if func (v) then table.insert (result, v) end end
    return result
    end

--[[----------------------------------------------------------------------------
public boolean 
arrayIn (array t, value [, func])

Returns true iff array "t" contains an element t [i] == value or, if "func"
is supplied, func (value, t [i]) is true.
------------------------------------------------------------------------------]]

function Util.arrayIn (t, value, func)
    for k, v in ipairs (t) do
        if (func == nil and v == value) or (func ~= nil and func (value, v)) 
        then
            return true
            end
        end
    return false
    end

--[[----------------------------------------------------------------------------
public array 
arrayAppend (array t1, t2)

Inserts all of the elements of array t2 at the end of array t1 in order,
returning t1.
------------------------------------------------------------------------------]]

function Util.arrayAppend (t1, t2)
    for i, v in ipairs (t2) do table.insert (t1, v) end
    return t1
    end


--[[----------------------------------------------------------------------------
public array 
subArray (array t, int i [,int n])

Returns a new array containing n elements from array t starting at index i.
More precisely, the new array contains elements x .. y of t, where: 

x = max (1, i)
y = min (#t, x + n - 1)

If n is missing, it defaults to #t.   If y < x the empty array is returned.
------------------------------------------------------------------------------]]

function Util.subArray (t, i, n)
    local result = {}
    n = n or #t
    local x = math.max (1, i)
    local y = math.min (#t, x + n - 1)
    local j = 1
    while x <= y do 
        result [j] = t [x]
        x, j = x + 1, j + 1
        end
    return result
    end

--[[----------------------------------------------------------------------------
public set 
arrayToSet (array t)

Converts the elements of array "t" into a set, i.e. a table "s" 
with s[e] = true for each element "e" of "t".
------------------------------------------------------------------------------]]

function Util.arrayToSet (t)
    local s = {}
    for _, e in ipairs (t) do s [e] = true end
    return s
    end

--[[----------------------------------------------------------------------------
public array 
setToArray (set s)

Converts the elements of set s into an array.  
------------------------------------------------------------------------------]]

function Util.setToArray (s)
    local t = {}
    for e, _ in pairs (s) do table.insert (t, e) end
    return t
    end

--[[----------------------------------------------------------------------------
public array 
tableMerge (table t1, t2)

Inserts all key/value pairs from t2 into t1.
------------------------------------------------------------------------------]]

function Util.tableMerge (t1, t2)
    for k, v in pairs (t2) do t1 [k] = v end
    return t1
    end


--[[----------------------------------------------------------------------------
public value 
tableReduce (table t, initialValue, func)

Returns func (func (func (initialValue, k1, v1), k2, v2), k3, v3) ...
for key/value pairs <ki, vi> in table t.
------------------------------------------------------------------------------]]

function Util.tableReduce (t, initialValue, func)
    local result = initialValue
    for k, v in pairs (t) do result = func (result, k, v) end
    return result
    end


--[[----------------------------------------------------------------------------
public array 
tableMap (table t, func)

Applies "func" to each key/value of "t" and returns an array of results:

{func (k1, v1), func (k2, v2), ...}

------------------------------------------------------------------------------]]

function Util.tableMap (t, func)
    local result = {}
    for k, v in pairs (t) do table.insert (result, func (k, v)) end
    return result
    end


--[[----------------------------------------------------------------------------
public boolean 
isTableEmpty (table t)

Returns true iff the table is empty.
------------------------------------------------------------------------------]]

function Util.isTableEmpty (t)
    for k, v in pairs (t) do return false end
    return true
    end


--[[----------------------------------------------------------------------------
public value 
deepCopy (x)

If "x" is not a table, returns "x".  If "x" is a table, returns a new 
table whose keys and values are deep copies of the corresponding keys and
values in "x".  No attempt is made to detect circularities.
------------------------------------------------------------------------------]]

function Util.deepCopy (x)
    if type (x) ~= "table" or Util.isSDKObject (x) then
        return x
    else
        local result = {}
        for i, v in pairs (x) do
            result [Util.deepCopy (i)] = Util.deepCopy (v)
            end
        return result
        end
    end
    

--[[----------------------------------------------------------------------------
public boolean 
deepEqual (x, y)

Returns true if x == y, or if x and y are both tables, if they have the same
keys and the keys and values are deepEqual().  No attempt is made to detect
circularities.
------------------------------------------------------------------------------]]

function Util.deepEqual (x, y)
    if x == y then 
        return true
    elseif type (x) ~= "table" or type (y) ~= "table" then
        return false
    elseif Util.isSDKObject (x) or Util.isSDKObject (y) then
        return false
    else
        if #x ~= #y then return false end
        for k, v in pairs (x) do
            if not Util.deepEqual (v, y [k]) then return false end
            end
        for k, v in pairs (y) do
            if x [k] == nil then return false end
            end
        return true
        end
    end
    

--[[----------------------------------------------------------------------------
public array of string
split (string s, string sepPattern)

Splits string "s" into fields, where "sepPattern" is a string.find pattern
defining the separation between the fields.  Returns the fields in an array.
If "s" ends in a separator pattern, then the last returned field will be the
empty string.
------------------------------------------------------------------------------]]

function Util.split (s, sepPattern)
    local result = {}
    local i = 1
    while true do
        local first, last = string.find (s, sepPattern, i)
        if not first then 
            table.insert (result, string.sub (s, i))
            return result
            end
        table.insert (result, string.sub (s, i, first - 1))
        if last >= #s then
            table.insert (result, "")
            return result
            end
        i = last + 1
        end
    end
            

--[[----------------------------------------------------------------------------
public string
escapeAmp (string s)

On Mac, returns "s", but on Windows, replaces all occurrences of "&" with
"&&" in "s".  Useful for contexts in which LR Windows interprets the "&" as
a Windows accelerator indicator, underlining the next character (LR bug).
------------------------------------------------------------------------------]]

function Util.escapeAmp (s)
    return MAC_ENV and s or s:gsub ("&", "&&")
    end


--[[----------------------------------------------------------------------------
public integer
firstUTF8Char (string s)

Returns the first UTF-8 character in "s". A UTF-8 code point either begins
with a byte from 0 to 127, or with a byte from 194 to 244 followed by 1-3
bytes from 128 to 191.  Returns nil if "s" doesn't start with a valid UTF-8
character.
------------------------------------------------------------------------------]]

function Util.firstUTF8Char (s)
    return s:match("^[%z\1-\127\194-\244][\128-\191]*") or nil
    end

--[[----------------------------------------------------------------------------
public integer
lineCount (string s)

Returns the number of lines needed to print "s". This is the number of
newlines, plus 1 if the last character isn't a newline.
------------------------------------------------------------------------------]]

function Util.lineCount (s)
    local n = 0
    for i = 1, #s do 
        if s:sub (i, i) == "\n" then n = n + 1 end
        end
    if s:sub (#s) ~= "\n" then n = n + 1 end
    return n
    end

--[[----------------------------------------------------------------------------
public string
cdCommand (string path)

Returns a shell command for changing the directory to the absolute "path".
The result has the form:

Mac: cd "<path>";
Windows: D: & cd \Users\john\plugins &

If "path" is a UNC path, an error is raised, since cmd.exe doesn't allow
cd's to a UNC path.  While you can "pushd", that would trigger the LR
import window to open automatically due to the temporary drive letter 
assigned.
------------------------------------------------------------------------------]]

function Util.cdCommand (path)
    if MAC_ENV then return format ('cd "%s"; ', path) end

    if path:sub (1, 2) == [[\\]] then 
        error ("Util.cdCommand: UNC paths not allowed: " .. path)
        end

    local ancestor, tail = path, ""
    while true do 
        local newAncestor = parent (ancestor)
        if newAncestor == nil then break end
        tail = "\\" .. leafName (ancestor) .. tail
        ancestor = newAncestor
        end

    if ancestor:sub (-1) == "\\" then ancestor = ancestor:sub (1, -2) end
    if tail == "" then tail = "\\" end
    return format ('%s & cd "%s" & ', ancestor, tail)
    end

--[[----------------------------------------------------------------------------
public int exitCode, string output, string errOutput
safeExecute (string commandLine [, boolean getOutput])

Executes the command line "commandLine"in the platform shell via
LrTasks.execute, working around a bug in execute() on Windows where quoted
program names aren't accepted.

If "getOutput" is true, "output" will contain standard out and standard
error and "errOutput" will be "".  If "getOutput" is "separate", then
"output" will contain standard out and "errOutput" will contain standard
error.  If "getOutput" is false, then both "output" and "errOutput" will be
"".

Returns in "exitCode" the exit code of the command line. If any errors
occur in safeExecute itself, "exitCode" will be -1, and "output" and
"errOutput" will be:

getOuptut == "separate": "", <error message>
otherwise:               <error message>, ""
------------------------------------------------------------------------------]]

function Util.safeExecute (commandLine, getOutput)
return Debug.callWithContext ("", function (context) 
    local outFile, errFile

    context:addCleanupHandler (function ()
        if outFile then LrFileUtils.delete (outFile) end
        if errFile then LrFileUtils.delete (errFile) end
        end)
        
    if getOutput then 
        local uuid = LrUUID.generateUUID ()
        outFile = child (getStandardFilePath ("temp"), uuid .. ".out")
        commandLine = commandLine .. ' > "' .. outFile .. '"'

        if getOutput == "separate" then
            errFile = child (getStandardFilePath ("temp"), uuid .. ".err")
            commandLine = commandLine .. ' 2>"' .. errFile .. '"'
        else
            commandLine = commandLine .. ' 2>&1'
            end
        end

    if WIN_ENV then commandLine = '"' .. commandLine .. '"' end
    local exitStatus = LrTasks.execute (commandLine)

    local output, errOutput, success = "", ""

    local function outputErr (file, output)
        local err = string.format ("Couldn't read output:\n%s\n%s", 
            file, output)
        if getOutput == "separate" then 
            return -1, "", err
        else
            return -1, err, ""
            end
        end

    if outFile then
        success, output = pcall (LrFileUtils.readFile, outFile)
        if not success then return outputErr (outFile, output) end
        end
    if errFile then
        success, errOutput = pcall (LrFileUtils.readFile, errFile)
        if not success then return outputErr (errFile, errOutput) end
        end

    return exitStatus, output, errOutput
    end) end
    
--[[----------------------------------------------------------------------------
public chunk, string err
safeLoadfile (string path)

Provides the equivalent of loadfile (path), except that it allows "path" to
contain non-ASCII characters (unlike the LR 3/4 SDK).  Returns the compiled
chunk, or nil and an error message. 
------------------------------------------------------------------------------]]

function Util.safeLoadfile (path)
    local success, contents = pcall (LrFileUtils.readFile, path)
    if not success then return nil, contents end
    return loadstring (contents, path)
    end        

--[[----------------------------------------------------------------------------
public string err
saveMetadata (LrPhoto photo)

Initiates a Metadata > Save Metadata To File for the photo and waits for
up to 2 seconds for it complete.

If a photo can't be saved, returns an error message in "err". Otherwise
returns nil.
------------------------------------------------------------------------------]]

function Util.saveMetadata (photo) 
    local path = photo:getRawMetadata ("path")

    local function returnErr (err)
        local msg = format ("Couldn't save metadata to file: %s\n%s",
            path, err)
        Debug.logn (msg)
        return msg
        end

    local startTime 
    for i = 1, math.huge do 
        startTime = floor (currentTime ())

            --[[ Sometimes photo:saveMetadata() fails with an obscure
            error, perhaps because of a race inside LR. Retrying 
            for up to 10 seconds seems to reduce the occurrences. ]]
        local success, err = LrTasks.pcall (photo.saveMetadata, photo)
        if success then 
            if i > 1 then 
                Debug.logn ("Util.saveMetadata:", i, 
                    "tries needed for successful save", path)
                end
            break
            end
        if i >= 10 and not success then return returnErr (err) end 
        LrTasks.sleep (1)
        end

    while true do
        if currentTime () > startTime + 2 then 
            return returnErr ("Timed out")
            end

        local modTime = fileAttributes (path).fileModificationDate or 0
        if modTime >= startTime then break end

        LrTasks.sleep (0.1)
        end

    return nil
    end

--[[----------------------------------------------------------------------------
public latestVersion
checkForNewVersion (string url, table version [, func (latestVersion)])

Checks for the availability of a new version, where versions are tables
of the form {major = number, minor = number}.

- url: The URL of where to find the latest version number; the content should be
text of the form "major.minor".

- version: The current verson of this plugin.

- func (latestVersion): Call asynchronously if the background task finds
a newer version.

If the latest version available is newer than "version", it is returned;
otherwise nil is returned.

This function returns immediately based on the previously recorded latest
version in prefs. But it also initiates a background check from "url", and if it
finds  a newer version, it calls func (latestVersion).
------------------------------------------------------------------------------]]
    
function Util.checkForNewVersion (url, version, func)
    local function vToN (v) return v.major * 10000 + v.minor end
    LrFunctionContext.postAsyncTaskWithContext ("checkVersion", 
    showErrors (function (context)
        local versionString, headers = LrHttp.get (url, nil, 15)
        if not versionString then return end

        local major, minor = versionString:match ("^(%d+)%.(%d+)")
        if not major then return end
        major = tonumber (major); minor = tonumber (minor) 
        if not major or not minor then return end
        prefs.latestVersion = {major = major, minor = minor}
        if func and vToN (prefs.latestVersion) > vToN (version) then 
            func (prefs.latestVersion)
            end
        end))

    if prefs.latestVersion and vToN (prefs.latestVersion) > vToN (version) then
        return prefs.latestVersion
    else
        return nil
        end
    end

--[[----------------------------------------------------------------------------
void
deletePrefs ()

Deletes all values in LrPrefs.prefsForPlugin().
------------------------------------------------------------------------------]]

function Util.deletePrefs ()
    for k, _ in LrPrefs.prefsForPlugin ():pairs () do 
        prefs [k] = nil 
        end
    end

--[[----------------------------------------------------------------------------
public LrPrefs prefs, boolean noChange
checkPrefsVersion (int prefsVersion, array of string protectedKeys)

Returns "noChange" = true if prefs.prefsVersion == prefsVersion. Otherwise,
deletes all key/value pairs from "prefs", sets prefs.version to "prefsVersion",
and returns "noChange" = false. Any key in the array "protectedKeys" is not
deleted. "protectedKeys" may be nil.  "prefs" is the preferences for the plugin.
------------------------------------------------------------------------------]]

function Util.checkPrefsVersion (prefsVersion, protectedKeys)
    local prefs = LrPrefs.prefsForPlugin ()
    if prefs.version == prefsVersion then
        return prefs, true
    else
        for k, v in prefs:pairs () do 
            if protectedKeys == nil or not Util.arrayIn (protectedKeys, k) then 
                prefs [k] = nil 
                end
            end
        prefs.version = prefsVersion
        return prefs, false
        end
    end

--[[----------------------------------------------------------------------------
public boolean 
isClass (object o)

Returns true if "o" is a class, false otherwise.
------------------------------------------------------------------------------]]

function Util.isClass (o)
    return type (o) == "table" and o.__index == o
    end


--[[----------------------------------------------------------------------------
public class 
class (object o)

Returns the class of object "o" or nil if it is not an instance of a class.
Note that if "o" is itself a class, class (o) is its superclass.
------------------------------------------------------------------------------]]

function Util.class (o)
    return getmetatable (o) 
    end


--[[----------------------------------------------------------------------------
public class 
superclass (object o)

If "o" is an instance of a class "c", returns the superclass of "c" or nil
if there is no superclass. If "o" is a class, returns its superclass or nil if
there is no superclass.  Returns nil if "o" is not a class or an instance
of a class.
------------------------------------------------------------------------------]]

function Util.superclass (o)
    if Util.isClass (o) then
        return getmetatable (o)
    else
        return getmetatable (getmetatable (o))
        end
    end


--[[----------------------------------------------------------------------------
public boolean 
isSubclassOf (object o, class c)

If "o" is an instance of class "c1", returns true if "c1" is "c" or a subclass
of "c".  If "o" is a class, returns true if "o" is "c" or a subclass of "c".
Returns false otherwise.
------------------------------------------------------------------------------]]

function Util.isSubclassOf (o, c)
    while true do
        if o == nil then return false end
        if o == c then return true end
        o = getmetatable (o)
        end
    end

--[[----------------------------------------------------------------------------
public integer
withPrivateWriteAccessDo (function f)
withWriteAccessDo (actionName, function f)

These call the corresponding catalog: methods, retrying if an error occurs
using a backoff algorithm and finally failing after a large number of retries.
Returns the number of retries in LR 3, nil in LR 4.

This works around an LR 3 bug in the SDK where there is no way to call "f"
atomically; if "f" calls any of the various SDK methods, such as
photo:setPropertyForPlugin(), whose implementations call yield, then we'll get
an error from trying to call withPrivateWriteAccessDo concurrently.  See this
thread:

http://feedback.photoshop.com/photoshop_family/topics/sdk_cant_call_setpropertyforplugin_from_multiple_tasks_bug_in_callwithcontext_noyield

LR 4 implemented its own timeout mechanism, which this function invokes.
------------------------------------------------------------------------------]]

local logMessage = "Util.%s: catalog:%s took %g seconds"

function Util.withPrivateWriteAccessDo (f) 
    return withAccessDo ("withPrivateWriteAccessDo",
        function (timeoutParams)
            return catalog:withPrivateWriteAccessDo (f, timeoutParams)
            end)
    end

function Util.withWriteAccessDo (actionName, f) 
    return withAccessDo ("withWriteAccessDo",
        function (timeoutParams)
            local r = catalog:withWriteAccessDo (actionName, f, timeoutParams)
            return r
            end)
    end

function withAccessDo (name, invoke)
    if LrApplication.versionTable ().major >= 4 then
        local result = invoke ({timeout = 30})
        if result == "aborted" then 
            error ("catalog:" .. name .. " timed out (30 seconds)")
            end
        return nil
        end

    local nRetries = 0
    local delay = 0.001
    while nRetries <= 100 do
        local success, err = pcall (invoke)
        if success then return nRetries end
        nRetries = nRetries + 1
        LrTasks.sleep (delay * (0.5 + math.random ()))
        delay = math.min (0.2, delay * 2)
        end
    invoke ()
    return nRetries
    end
        

--[[----------------------------------------------------------------------------
public value
safeDoFile (string path)

Provides the equivalent of dofile (path), except that it allows "path" to
contain non-ASCII characters (unlike the LR 3/4 SDK).  Returns the result of
executing the file. Throws an error if the path can't be read or if the file's
code throws an error.
------------------------------------------------------------------------------]]

function Util.safeDoFile (path)
    local success, contents = pcall (LrFileUtils.readFile, path)
    if not success then error (contents) end
    local chunk, e = loadstring (contents, path)
    if not chunk then error (e) end
    return chunk ()
    end        

--[[----------------------------------------------------------------------------
void
showBezel (string message, bool fallBackToDialog, number duration)

Invokes LrDialogs.showBezel() on LR 5 and later, but if "fallBackToDialog" is
true, popping up a standard confirmation dialog for earlier versions that don't
support showBezel().
------------------------------------------------------------------------------]]

function Util.showBezel (message, fallBackToDialog, duration)
    duration = duration or 1.5
    if LrApplication.versionTable ().major >= 5 then
        LrTasks.sleep (0.25) 
            --[[ Changing current active-source folders seems to shut down
            the bezel message prematurely.  Sleeping a little makes it 
            better. ]]
        LrDialogs.showBezel (message, duration)
    elseif fallBackToDialog then
        LrDialogs.message (message, nil, "info")
        end
    end


--[[----------------------------------------------------------------------------
public string
valueToString (value v)

Returns the value "v" as a string in Lua-expression form, suitable for
reading back in.   Only data that can be printed with Debug.pp() can be
read back in.
------------------------------------------------------------------------------]]

function Util.valueToString (v)
    return Debug.pp (v, 0, math.huge, math.huge)
    end

--[[----------------------------------------------------------------------------
public value, errorMsg
stringToValue (string s)

Executes the string "s" (created by valueToString (v)) to return a value
equivalent to "v".   If no error occurs, returns <value, nil>; otherwise
returns <nil, errorMsg>.
------------------------------------------------------------------------------]]

function Util.stringToValue (s)
    local chunk, errorMsg = loadstring ("return " .. s)
    if not chunk then return nil, errorMsg end
    local success, v = pcall (chunk)
    if not success then return nil, v end
    return v, nil
    end

--[[----------------------------------------------------------------------------
public value, errorMsg
writeValue (string path, value v)

Writes valueToString(v) to file "path".  If no error occurs, returns
<value, nil>; otherwise returns <nil, error message>.
------------------------------------------------------------------------------]]

function Util.writeValue (path, v)
    local file, errorMsg = io.open (path, "w")
    if file == nil then return nil, errorMsg end
    local success, errorMsg = file:write (Util.valueToString (v))
    if not success then 
        file:close ()
        return nil, errorMsg 
        end
    local success, errorMsg = file:close ()
    if not success then return nil, errorMsg end
    return v, nil
    end

--[[----------------------------------------------------------------------------
public value, errorMsg
readValue (string path)

Reads the value stored in file "path" (written by writeValue()). If no
error occurs, returns <value, nil>; otherwise returns <nil, error message>.
------------------------------------------------------------------------------]]

function Util.readValue (path)
    local success, s = pcall (LrFileUtils.readFile, path )
    if not success then return nil, s end
    return Util.stringToValue (s)
    end

--[[----------------------------------------------------------------------------
public string path, string errorMsg
writeFile (string path, string s)

Writes "s" to the file "path". If "path" is nil, a unique temp file is
created. If no error occurs, return <path to file, nil>; otherwise returns
<nil, error message>
------------------------------------------------------------------------------]]

function Util.writeFile (path, s)
    if path == nil then 
        path = child (getStandardFilePath ("temp"), generateUUID ())
        end
    local file, errorMsg = io.open (path, "w")
    if file == nil then return nil, errorMsg end
    local success, errorMsg = file:write (s)
    if not success then 
        file:close ()
        return nil, errorMsg 
        end
    local success, errorMsg = file:close ()
    if not success then return nil, errorMsg end
    return path, nil
    end

--[[----------------------------------------------------------------------------
public any 
try {function f1, finally = function f2}

Calls f1 (), returning its result.  No matter how f1 exits (normally or 
on error), f2 () is then called.
------------------------------------------------------------------------------]]

function Util.try (blocks)
    return Debug.callWithContext ("try", function (context)
        context:addCleanupHandler (function () blocks.finally () end)
        return blocks [1] () 
        end)
    end

--[[----------------------------------------------------------------------------
Mutex

A mutex is a mutual-exclusion lock, implemented as a "polite" spin lock. In
theory, locks shouldn't be necessary with the non-preemptive LR tasks, but
there are too many places in the SDK API where LR will yield to another
task, and the client has no control over that.

Mutex
Mutex:new ([number initialWaitTime, [number maxWaitTime])

    Makes a new mutex.  "initialWaitTime" (default 0.001) is the initial
    number of seconds that :acquire() will wait if another task currently
    has the mutex.  Each subsequent wait will be twice as long, up to 
    a maximum of "maxWaitTime" (default 0.1).

mutex:acquire ()
    Acquires the mutex, waiting if necessary until the mutex is available.

mutex:release ()
    Releases the mutex.
------------------------------------------------------------------------------]]

Util.Mutex = {}
Util.Mutex.__index = Util.Mutex

function Util.Mutex:new (initialWaitTime, maxWaitTime)
    local mutex = {}
    setmetatable (mutex, self)
    mutex.locked = false  
    mutex.initialWaitTime = initialWaitTime or 0.001
    mutex.maxWaitTime = maxWaitTime or 0.1
    return mutex
    end

function Util.Mutex:acquire ()
    local time = self.initialWaitTime
    while self.locked do
        LrTasks.sleep (time)
        time = math.min (self.maxWaitTime, 2 * time)
        end
    self.locked = true
    end

function Util.Mutex:release ()
    assert (self.locked, "Mutex:release called on unlocked mutex")
    self.locked = false
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

"keys" can also be a single string.
------------------------------------------------------------------------------]]

function Util.bindKeys (keys, f, prop)
    if type (keys) == "string" then keys = {keys} end
    return LrView.bind {keys = keys, bind_to_object = prop, 
        operation = showErrors (function (binder, values, fromTable)
            if fromTable then return f (values) end
            return LrBinding.kUnsupportedDirection
            end)}
    end

--[[----------------------------------------------------------------------------
------------------------------------------------------------------------------]]

function Util.moveFile(sourcePath, destPath)
    if WIN_ENV then
        return Util.safeExecute("move \""..sourcePath.."\" \""..destPath.."\"")
    else
        return Util.safeExecute("mv \""..sourcePath.."\" \""..destPath.."\"")
    end
end

return Util