return {
	
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 6.0, -- minimum SDK version required by this plug-in

	LrToolkitIdentifier = 'com.iwillwen.automark',

	LrPluginName = "AutoMark 快速标记",
	
	-- Add the menu item to the File menu.
	
	-- LrExportMenuItems = {
	-- 	title = "Auto Mark",
	-- 	file = "ExportMenuItem.lua",
	-- },

	-- Add the menu item to the Library menu.
	
	LrLibraryMenuItems = {
		{
			title = "快速标记图片",
			file = "AutoMark.lua",
		},
		{
			title = "修改相机信息",
			file = "EditCamera.lua",
		},
	},
	VERSION = { major=1, minor=0, revision=0, build="202201281441-a5b5f472", },

}


	
