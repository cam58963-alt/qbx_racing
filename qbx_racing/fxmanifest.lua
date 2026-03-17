fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'QBX Racing Team'
description 'QBX Racing System - Complete Multiplayer Racing with Ghost Mode'
version '4.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

client_scripts {
    'client/main.lua',
    'client/race_logic.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/script.js'
}

dependencies {
    'qbx_core',
    'ox_lib',
    'oxmysql'
}
