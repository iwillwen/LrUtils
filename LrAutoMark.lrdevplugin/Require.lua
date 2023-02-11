--[[----------------------------------------------------------------------------
12345678901234567890123456789012345678901234567890123456789012345678901234567890

Require

Copyright 2010, John R. Ellis -- You may use this script for any purpose, as
long as you include this notice in any versions derived in whole or part from
this file.


This module replaces the standard "require" with one that provides the ability
to reload all files and to define a search path for loading .lua files from
shared directories.  For an introductory overview, see the accompanying
"Debugging Toolkit.htm".

Overview of the public interface; for details, see the particular function:

value require (string filename, [, reload])
    Loads a file if it hasn't already been loaded. 
    
namespace path (...)
    Sets the search path for source directories.
    
namespace loadDirectory (string dir)  
    Sets the base directory from where files are loaded.
    
namespace reload (boolean or nil force) 
    Specifies whether subsequent 'require's reload files.

string or nil findFile (filename)
    Searches for a file in the current search path of source directories.
    
table newGlobals ()    
    Returns all global names defined since the initial require.
------------------------------------------------------------------------------]]

local Require = {}

local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local child = LrPathUtils.child
local exists = LrFileUtils.exists
local isRelative = LrPathUtils.isRelative
local makeAbsolute = LrPathUtils.makeAbsolute

local Debug
    --[[ To break load dependencies and allow Debug.lua to be located in 
    another directory than the plugin, Debug.lua is loaded the first
    time require() is called. ]]
    
local originalRequire
    --[[ The original values of "require". ]]
    
local level = 0
    --[[ The level of nesting of currently executing require's.  Level = 1
    means the outermost require. ]]

local filenameLoaded = {}
    --[[ Table mapping filename => true, indicating the file has been loaded
    by loadFile/debugRequire. ]]
    
local filenameResult = {}
    --[[ Table mapping filename => value of loading the file. ]]
    
local originalG 
    --[[ Shallow copy of _G at the start of loading the top-level file. ]]

local nameIsNewGlobal = {}
    --[[ Table mapping a name to true if it has been defined in _G by the 
    top-level require or a nested require. ]]

local filenameNewGlobals = {}
    --[[ Table mapping filename to a table containing all the globals defined by
    loading that file. The table of globals maps a global name to its value
    at the time of loading. ]]

local loadDir
    --[[ The directory from which loadFile and debugRequire will load files.
    If nil, then defaults to _PLUGIN.path ]]
    
local pathDirs = {"."}
    --[[ List of directories that will be searched for the file.  The first
    directory is always ".".  All directories are relative to the _PLUGIN.path.
    ]]

    -- Forward references
local safeLoadfile

--[[----------------------------------------------------------------------------
public value
require (string filename, [, reload])

This version of require is similar to the standard one, but it allows control
over whether files are reloaded and it tracks which files define which new
globals.  If "reload" is true, then the file is loaded regardless if it
had already been loaded.
------------------------------------------------------------------------------]]

function Require.require (filename, reload) 
return LrFunctionContext.callWithContext ("", function (context)
    if type (filename) ~= "string" then 
        error ("arg #1 to 'require' not a string", 2)
        end
    if LrPathUtils.extension (filename) == "" then 
        filename = filename .. ".lua"
        end

    if filename == "Require.lua" then return Require end

    if not Debug and filename ~= "Debug.lua" then 
        pcall (function () Debug = Require.require ("Debug") end)
        end
    
    if filename == "Debug.lua" and Debug then return Debug end

    if not reload and filenameLoaded [filename] then
        return filenameResult [filename]
        end
    
    if not originalG then
        originalG = table.shallowcopy (_G)
        setmetatable (originalG, nil)
        end

    level = level + 1
    context:addCleanupHandler (function () level = level - 1 end)

    local function raiseError (msg)
        error (string.format ("'require' can't open script '%s': %s", 
            filename, msg), 2)
        end

    local fullPath, relativePath = Require.findFile (filename) 
    if not fullPath then raiseError ("can't find the file") end
    local chunk, e = safeLoadfile (fullPath, relativePath)
    if not chunk then error (e, 0) end
    if level == 1 and Debug and Debug.enabled then 
        chunk = Debug.showErrors (chunk) 
        end
    local success, value = LrTasks.pcall (chunk)

    if success then 
        filenameLoaded [filename] = true
        filenameResult [filename] = value
        end
    
    local newGlobals = {}
    local foundNewGlobal = false
    for k, v in pairs (_G) do 
        if originalG [k] == nil and not nameIsNewGlobal [k] then
            nameIsNewGlobal [k] = true
            newGlobals [k] = v            
            foundNewGlobal = true 
            end
        end    
    if foundNewGlobal then filenameNewGlobals [filename] = newGlobals end
    
    if not success then 
        error (value, 0)
    else
        return value
        end
    end) end
    

--[[----------------------------------------------------------------------------
void chunk, err
safeLoadfile (string fullPath, string relativePath)

Provides the equivalent of loadfile (fullPath), except that it allows
"path" to contain non-ASCII characters (unlike the LR 3/4 SDK).  Returns
the compiled chunk, or nil and an error message.  "relativePath" is the
relative file path passed as the chunk name to loadstring (), which we want
recorded as the source for debugging purposes.
------------------------------------------------------------------------------]]

function safeLoadfile (fullPath, relativePath)
    local success, contents = LrTasks.pcall (LrFileUtils.readFile, fullPath)
    if not success then return nil, contents end
    return loadstring (contents, relativePath)
    end        

--[[----------------------------------------------------------------------------
public namespace
path (...)

Sets a search path of directories to search for required files. "." is always
implicitly included at the front of the path.  Each argument should be a string
containing a directory path, and each path can be absolute or relative to the
directory set by loadDirectory() (which defaults to _PLUGIN.path).  Returns the
Require module.
------------------------------------------------------------------------------]]

function Require.path (...)
    pathDirs = {"."}
    for i = 1, select ("#", ...) do 
        local dir = select (i, ...)
        table.insert (pathDirs, dir)
        end
    return Require
    end

--[[----------------------------------------------------------------------------
public array of string
pathDirectories ()

Returns the current search path of directories used to search for files;
each directory in the result is an absolute path.
------------------------------------------------------------------------------]]

function Require.pathDirectories ()
    local dirs = {}
    for _, pathDir in ipairs (pathDirs) do 
        local fullPathDir = not isRelative (pathDir) and pathDir or 
            makeAbsolute (pathDir, loadDir or _PLUGIN.path)
        table.insert (dirs, fullPathDir)
        end

    return dirs
    end

--[[----------------------------------------------------------------------------
public namespace
loadDirectory (string dir)

Sets the directory from which files will be loaded (defaults to _PLUGIN.path).
A value of nil (the default) causes files to be loaded from the plugin
directory. Returns the Require module.
------------------------------------------------------------------------------]]

function Require.loadDirectory (dir)
    loadDir = dir
    return Require
    end


--[[----------------------------------------------------------------------------
public string fullPath, string relativePath
findFile (filename)

If "filename" is an absolute path, it is returned as both "fullPath" and
"relativePath".

If "filename" is relative, the path directories are searched for the first
one containing it.  Returns the fully qualified path name and path name
relative to the search directories if it is found; otherwise returns nil,
nil.
------------------------------------------------------------------------------]]

function Require.findFile (filename)
    if not isRelative (filename) then return filename, filename end

    for _, pathDir in ipairs (pathDirs) do
        local relativePath = pathDir == "." and filename or 
            child (pathDir, filename)
        local fullPathDir = not isRelative (pathDir) and pathDir or 
            makeAbsolute (pathDir, loadDir or _PLUGIN.path)      
        local fullPath = child (fullPathDir, filename)
        if exists (fullPath) then return fullPath, relativePath end
        end

    return nil
    end


--[[----------------------------------------------------------------------------
public namespace
reload (boolean or nil force)

If "force" is true, or if "force" is nil and the plugin directory's name ends in
".lrdevplugin", then all information about previously loaded modules is
immediately discarded, forcing them to be reloaded by subsequent 'require's.

A useful idiom is to do the following at the top of the root script:

    require 'Require'.reload()

When debugging (e.g. when running from a ".lrdevplugin" directory), this will
force all subsequent nested scripts to be reloaded; but when run from a
"release" directory (".lrplugin"), a 'require'd script will be loaded at most
once.

Returns the Require module.
------------------------------------------------------------------------------]]

function Require.reload (force)
    if force == true or 
       (force == nil and _PLUGIN.path:sub (-12) == ".lrdevplugin") 
    then
        filenameLoaded = {}
        filenameResult = {}
        nameIsNewGlobal = {}
        filenameNewGlobals = {}
        originalG = nil
        end
    return Require
    end


--[[----------------------------------------------------------------------------
public table
newGlobals ()

Returns a table containing the new globals that were defined by each loaded file
since the beginning or the last call to reload ().  Has the form:

{filename1 => {name1 => value1, name2 => value2 ...},
 filename 2 => {name3 => value 3, name4 => value4 ...}, ...}
 
Clears the table after returning it. 
------------------------------------------------------------------------------]]

function Require.newGlobals ()
    local result = filenameNewGlobals
    filenameNewGlobals = {}
    return result
    end
    

--[[----------------------------------------------------------------------------
------------------------------------------------------------------------------]]

originalRequire = require
require = Require.require

return Require