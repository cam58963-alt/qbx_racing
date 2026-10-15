fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'CAM Racing Team'
description 'CAM Racing System - Complete Multiplayer Racing with Ghost Mode'
version '4.2.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/database.lua',
    'server/main.lua'
}

client_scripts {
    'client/markers.lua',
    'client/main.lua',
    'client/race_logic.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/script.js',
    'html/img/markers/*.png'
}

dependencies {
    'qbx_core',
    'ox_lib',
    'oxmysql'
}
