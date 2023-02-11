local Require = require "Require".path ("../debuggingtoolkit.lrdevplugin").reload ()
local Debug = require "Debug".init ()

require "strict"

local LrFileUtils = import "LrFileUtils"
local LrDialogs = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local Util = require "Util"

local cmdPath = LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "exiftool"), "exiftool")
if WIN_ENV then
  cmdPath = LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "exiftool"), "exiftool.exe")
end

ExifTool = {}

function ExifTool.editCameraInfo(path, make, model, uniqueModel)
  local commandLine = cmdPath.." -make=\""..make.."\" -model=\""..model.."\" -uniquecameramodel=\""..uniqueModel.."\" "..path

  -- LrDialogs.message('command line', commandLine)

  local exitStatus, output, errOutput = Util.safeExecute(commandLine, true)

  -- LrDialogs.message('debug ouput', output)

  LrFileUtils.delete(path.."_original")
end


return ExifTool
