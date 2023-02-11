local Require = require "Require".path ("../debuggingtoolkit.lrdevplugin").reload ()

local Debug = require "Debug".init ()

require "strict"

local LrApplication = import "LrApplication"
local LrFunctionContext = import "LrFunctionContext"
local LrDialogs = import "LrDialogs"
local LrBinding = import "LrBinding"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrStringUtils = import "LrStringUtils"
local LrLogger = import "LrLogger"
local LrColor = import "LrColor"
local LrHttp = import "LrHttp"

local Util = require "Util"

local logger = LrLogger("AutoMark")
logger:enable("print")

AutoMark = {}

function AutoMark.showDialog()
  LrFunctionContext.callWithContext("showDialog", function(context)
    local props = LrBinding.makePropertyTable(context)
    props.value = ""

    local f = LrView.osFactory()

    local c = f:column {
      bind_to_object = props,
      spacing = f:label_spacing(),
      
      f:row {
        spacing = f:label_spacing(),
        f:static_text {
          title = "请输入需要自动标记照片的关键词，以英文逗号隔开或每行一个。"
        },
      },
    
      f:row {
        spacing = f:label_spacing(),

        f:edit_field {
          value = LrView.bind("value"),
          width_in_chars = 35,
          height_in_lines = 15,
        },
      },

      f:row {
        spacing = f:label_spacing(),

        f:static_text {
          text_color = LrColor("blue"),
          title = "可以使用 https://photo-picker.wwen.pro/ 进行快速图片选择。",
          mouse_down = function ()
            LrHttp.openUrlInBrowser("https://photo-picker.wwen.pro/")
          end
        }
      },
    }

    local result = LrDialogs.presentModalDialog(
      {
        title = "自动标记",
        contents = c,
      }
    )
    if result == "ok" then
      AutoMark.markingPhotosWithInputValue(props.value)
    end
  end)
end

function AutoMark.markingPhotosWithInputValue(value)
  local normalizedValue = LrStringUtils.trimWhitespace(value)
  local keywordList = Util.split(normalizedValue, "\r\n,")

  local keywords = {}
  
  for _, line in ipairs(keywordList) do
    local row = Util.split(line, ".")
    local filename = row[1]

    table.insert(keywords, filename)
  end

  logger:trace("AutoMark: find "..tostring(#keywords).." keywords." )

  local catalog = LrApplication.activeCatalog()
  
  LrTasks.startAsyncTask(function ()
    logger:trace("AutoMark: start to marking photos." )

    catalog:withWriteAccessDo("自动标记", function (context)
      local markedCount = 0

      for _, keyword in ipairs(keywords) do
        logger:trace("AutoMark: Start to find photos with keyword "..keyword)
  
        local foundPhotos = catalog:findPhotos {
          searchDesc = {
            criteria = "all",
            operation = "any",
            value = keyword,
          }
        }
  
        logger:trace("AutoMark: Found "..tostring(#foundPhotos).." photos with keyword \""..keyword.."\"")
  
        for _, photo in ipairs(foundPhotos) do
          photo:setRawMetadata("pickStatus", 1)
          logger:trace("Marked Photo "..photo:getFormattedMetadata("fileName"))
          markedCount = markedCount + 1
        end
  
      end
  
      LrDialogs.message("标记完成", "已对 "..tostring(markedCount).." 张照片进行标记。")

      catalog:setViewFilter {
        pick = "flagged",
      }
    end)
  end)
end

AutoMark.showDialog()