fx_version 'bodacious'

version '0.17.2'

game "gta5"

node_version '22'

lua54 'yes'

-- client em Lua (fork MRI): ver game/client.lua
client_script "game/client.lua"
server_script "game/dist/server.js"

ui_page "game/nui/dist/index.html"
files {
    "game/nui/dist/index.html",
    "game/nui/dist/**/*",
}

provide 'screenshot-basic'

-- use 'nui' if you're having trouble with uploads
protocol 'http'

-- bytes per second for nui protocol
-- change this as you like
images_bps '1000000'
stream_bps '5000000'