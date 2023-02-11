local Require = require "Require".path ("../debuggingtoolkit.lrdevplugin").reload ()

local Debug = require "Debug".init ()

require "strict"

local LrApplication = import "LrApplication"
local LrFunctionContext = import "LrFunctionContext"
local LrDialogs = import "LrDialogs"
local LrBinding = import "LrBinding"
local LrView = import "LrView"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local LrStringUtils = import "LrStringUtils"
local LrLogger = import "LrLogger"
local LrColor = import "LrColor"
local LrHttp = import "LrHttp"
local LrExportSession = import "LrExportSession"
local bind = LrView.bind

local ExifTool = require "ExifTool"
local Util = require "Util"
local JSON = require "JSON"

local rawCamerasJSON = LrFileUtils.readFile(LrPathUtils.child(_PLUGIN.path, "resources/cameras.json"))
local camerasData = JSON:decode(rawCamerasJSON)
local allCameraModels = Util.arrayReduce(
  Util.arrayMap(camerasData, function (row)
    return row.models
  end),
  {},
  function (modelsA, modelsB)
    return Util.arrayAppend(modelsA, modelsB)
  end
)

local logger = LrLogger("EditModel")
logger:enable("print")

local TEMP_PATH = LrPathUtils.child(_PLUGIN.path, "tmp_dng")
LrFileUtils.createAllDirectories(TEMP_PATH)

EditModel = {}

function EditModel.showDialog()
  LrFunctionContext.callWithContext("showDialog", Debug.showErrors (function(context)

    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()
    local selectedPhotosCount = #selectedPhotos

    local props = LrBinding.makePropertyTable(context)
    props.select_type = "selection"
    props.cameraMake = camerasData[1].value
    props.cameraModel = camerasData[1].models[1].value
    props.availableModels = camerasData[1].models

    -- Binding camera model to make
    props:addObserver('cameraMake', function (properties, key, newValue)
      props.availableModels = {}

      local make = Util.arrayFilter(camerasData, function (row)
        if row.value == newValue then
          return true
        end

        return false
      end)[1]

      if make then
        props.availableModels = make.models
        props.cameraModel = make.models[1].value
      end

    end)

    local f = LrView.osFactory()

    local c = f:column {
      bind_to_object = props,
      spacing = f:label_spacing(),

      f:row {
        spacing = f:label_spacing(),
        fill_horizontal = 1,
        f:group_box {
          title = "调整目标",
          fill_horizontal = 1,
          spacing = f:control_spacing(),

          f:radio_button {
            title = "当前选择照片（已选择 "..tostring(selectedPhotosCount).." 张）",
            value = bind 'select_type',
            checked_value = 'selection',
          },
          f:radio_button {
            title = "当前所有照片",
            value = bind 'select_type',
            checked_value = 'all_in_catalog',
          },
          f:static_text {
            text_color = LrColor('gray'),
            title = "请注意，该操作会对选择照片进行复制操作，建议分批处理。"
          },
        },
      },

      f:row {
        spacing = f:control_spacing(),
        fill_horizontal = 1,
        
        f:group_box {
          title = "目标相机信息",
          fill_horizontal = 1,
          spacing = f:control_spacing(),

          f:row {
            spacing = f:control_spacing(),
            fill_horizontal = 1,

            f:static_text {
              title = "相机生产商",
              alignment = 'right',
            },

            f:popup_menu {
              fill_horizonal = 1,
              value = bind 'cameraMake',
              items = Util.arrayMap(camerasData, function (make)
                return {
                  title = make.title,
                  value = make.value
                }
              end)
            },
          },

          f:row {
            spacing = f:control_spacing(),
            fill_horizontal = 1,

            f:static_text {
              title = "相机型号",
              alignment = 'right',
            },

            f:popup_menu {
              fill_horizonal = 1,
              value = bind 'cameraModel',
              items = bind 'availableModels'
            },
          },
        }
      }
    }

    local result = LrDialogs.presentModalDialog(
      {
        title = "修改相机信息",
        contents = c,
      }
    )
    if result == "ok" then
      EditModel.editCameraInfo(props)
    end
  end))
end

function EditModel.editCameraInfo(props)

  local catalog = LrApplication.activeCatalog()
  local selectedPhotos = catalog:getTargetPhotos()

  local photosToExport = {}

  local model = props.cameraModel
  local uniqueModel = model
  local targetModels = Util.arrayFilter(allCameraModels, function (row)
    return row.value == model
  end)
  if targetModels[1] ~= nil and targetModels[1].uniqueCameraModel ~= nil then
    uniqueModel = targetModels[1].uniqueCameraModel
  end

  if props.select_type == "selection" then
    photosToExport = selectedPhotos
  elseif props.select_type == "all_in_catalog" then
    photosToExport = catalog:getAllPhotos()
  end

  LrTasks.startAsyncTask(function ()
    logger:trace("EditModel: start to exporting DNG file" )
    
    local exportSession = LrExportSession({
      photosToExport = photosToExport,
      exportSettings = {
        LR_format = "DNG",
        LR_DNG_previewSize = "medium",
        LR_DNG_compatability = "84148224",
        LR_DNG_conversionMethod = "preserveRAW",
        LR_DNG_embedRAW = false,
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = TEMP_PATH,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "ask",
        LR_extensionCase = "uppercase",
        LR_tokens = "{{image_originalName}}",
      },
    })

    exportSession:doExportOnCurrentTask()

    catalog:withWriteAccessDo("addPhotos", function (context)
      local editedCount = 0

      for i, rendition in exportSession:renditions() do
        ExifTool.editCameraInfo(rendition.destinationPath, props.cameraMake, props.cameraModel, uniqueModel)

        local fileName = LrPathUtils.leafName(rendition.destinationPath)
        local sourceFolderPath = LrPathUtils.parent(rendition.photo:getRawMetadata('path'))
        local newFilePath = LrPathUtils.child(sourceFolderPath, fileName)

        logger:trace('debug: tmp path', rendition.destinationPath)
        logger:trace('debug: source path', sourceFolderPath)
        local moveRes, errorMsg = Util.moveFile(rendition.destinationPath, sourceFolderPath)

        logger:trace('debug: move res', moveRes)
        logger:trace('debug: move error message', errorMsg)

        local dngPhoto = catalog:addPhoto(newFilePath, rendition.photo, 'above')
        dngPhoto:setRawMetadata("colorNameForLabel", "green")

        editedCount = editedCount + 1
      end

      LrDialogs.message("修改完成", "已对 "..tostring(editedCount).." 张照片进行修改。")
    end)
  end)
end

EditModel.showDialog()