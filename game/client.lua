-- Client do screencapture em Lua (fork mri-Qbox-Brasil).
--
-- Porta 1:1 de game/client/bootstrap.ts + protocols/nui.ts. Em JS o runtime do
-- FiveM roda todo frame mesmo sem nada agendado (~0.02ms parado no resmon); em
-- Lua o resource só roda quando chega um evento. O server continua em JS.
-- Ao puxar mudanças do upstream no client TS, portar aqui também.

local RESOURCE = GetCurrentResourceName()

local protocol = GetResourceMetadata(RESOURCE, 'protocol', 0) or 'http'
if protocol == '' then protocol = 'http' end
local serverEndpoint = ('http://%s/%s'):format(GetCurrentServerEndpoint(), RESOURCE)
local imagesBps = tonumber(GetResourceMetadata(RESOURCE, 'images_bps', 0)) or 500000
local streamBps = tonumber(GetResourceMetadata(RESOURCE, 'stream_bps', 0)) or 5000000
local STREAM_ACK_TIMEOUT = 60000

local captureCallbacks = {} ---@type table<string, function>
local uploadTokens = {} ---@type table<string, string>

local function uuid()
    return (('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'):gsub('[xy]', function(c)
        local v = c == 'x' and math.random(0, 15) or math.random(8, 11)
        return ('%x'):format(v)
    end))
end

local function nuiUrl(name)
    return ('https://%s/%s'):format(RESOURCE, name)
end

---Cópia rasa de `base` com os campos de `extra` por cima (o `{ ...a, ...b }` do JS).
local function merge(base, extra)
    local out = {}
    if type(base) == 'table' then
        for k, v in pairs(base) do out[k] = v end
    end
    for k, v in pairs(extra) do out[k] = v end
    return out
end

---Ida e volta com o server: `send` manda o evento com o nome de resposta
---único e aqui espera o server responder nele. Chamar dentro de uma thread.
---@param timeout number? ms; sem resposta, resolve com `onTimeout`
local function awaitServer(responseEvent, send, timeout, onTimeout)
    local p = promise.new()
    local done = false
    local handler
    handler = RegisterNetEvent(responseEvent, function(data)
        if done then return end
        done = true
        RemoveEventHandler(handler)
        p:resolve(data)
    end)
    if timeout then
        SetTimeout(timeout, function()
            if done then return end
            done = true
            RemoveEventHandler(handler)
            p:resolve(onTimeout)
        end)
    end
    send()
    return Citizen.Await(p)
end

---Compat com o `provide 'screenshot-basic'`: exports['screenshot-basic']:fn().
local function exportBoth(name, fn)
    exports(name, fn)
    AddEventHandler(('__cfx_export_screenshot-basic_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

local function createImageCaptureMessage(options)
    local message = merge(options, { action = 'capture' })
    if protocol == 'http' then message.serverEndpoint = serverEndpoint .. '/upload' end
    SendNUIMessage(message)
end

--------------------------------------------------------------------------------
-- Captura pedida pelo server
--------------------------------------------------------------------------------

RegisterNetEvent('screencapture:captureScreen', function(token, options, dataType)
    if protocol == 'nui' then
        return SendNUIMessage(merge(options, {
            uploadToken = token,
            callbackUrl = nuiUrl('capture_screen'),
            dataType = dataType,
            action = 'capture',
        }))
    end
    SendNUIMessage(merge(options, {
        uploadToken = token,
        dataType = dataType,
        action = 'capture',
        serverEndpoint = serverEndpoint .. '/upload',
    }))
end)

RegisterNetEvent('screencapture:INTERNAL_uploadComplete', function(response, correlationId)
    local callback = captureCallbacks[correlationId]
    if callback then
        captureCallbacks[correlationId] = nil
        callback(response)
    end
end)

RegisterNetEvent('screencapture:captureStream', function(token, options, captureId)
    if protocol == 'nui' then
        return SendNUIMessage(merge(options, {
            captureId = captureId,
            uploadToken = token,
            action = 'capture-stream-start',
            callbackUrl = nuiUrl('capture_stream_chunk'),
            finalizeCallbackUrl = nuiUrl('capture_stream_finalize'),
        }))
    end
    SendNUIMessage(merge(options, {
        captureId = captureId,
        uploadToken = token,
        action = 'capture-stream-start',
        serverEndpoint = serverEndpoint,
    }))
end)

RegisterNetEvent('screencapture:INTERNAL:stopCaptureStream', function(captureId)
    SendNUIMessage({ action = 'capture-stream-stop', captureId = captureId })
end)

RegisterNetEvent('screencapture:liveStream:start', function(request)
    SendNUIMessage(merge(request, {
        action = 'live-stream-start',
        statusCallbackUrl = nuiUrl('live_stream_status'),
    }))
end)

RegisterNetEvent('screencapture:liveStream:stop', function(streamId)
    SendNUIMessage({ action = 'live-stream-stop', streamId = streamId })
end)

--------------------------------------------------------------------------------
-- Exports (screencapture e screenshot-basic)
--------------------------------------------------------------------------------

local function requestScreenshotUpload(url, formField, optionsOrCB, callback)
    local isOptions = type(optionsOrCB) == 'table' and callback ~= nil
    local options = isOptions and optionsOrCB or { encoding = 'webp' }
    local realCallback = isOptions and callback or optionsOrCB

    local correlationId = uuid()
    captureCallbacks[correlationId] = realCallback

    CreateThread(function()
        local event = 'screencapture:INTERNAL_requestUploadToken'
        local responseEvent = ('%s:%s'):format(event, uuid())
        local token = awaitServer(responseEvent, function()
            TriggerServerEvent(event, responseEvent, merge(options, {
                formField = formField,
                url = url,
                correlationId = correlationId,
            }))
        end)

        if not token then
            captureCallbacks[correlationId] = nil
            return print('^1[screencapture] Failed to get upload token^0')
        end

        uploadTokens[correlationId] = token
        createImageCaptureMessage(merge(options, {
            formField = formField,
            url = url,
            uploadToken = token,
            dataType = 'base64',
            correlationId = correlationId,
            -- passa pelo proxy da NUI, então fica assim mesmo
            callbackUrl = nuiUrl('screenshot_upload_proxy'),
        }))
    end)
end

exportBoth('requestScreenshotUpload', requestScreenshotUpload)

local function requestScreenshot(options, callback)
    local realOptions = callback ~= nil and options or { encoding = 'jpg' }
    local realCallback = callback ~= nil and callback or options
    if not realCallback then
        return print('^1[screencapture] Callback is not a function^0')
    end

    local correlationId = uuid()
    captureCallbacks[correlationId] = realCallback

    createImageCaptureMessage(merge(realOptions, {
        callbackUrl = nuiUrl('screenshot_created'),
        correlationId = correlationId,
    }))
end

exportBoth('requestScreenshot', requestScreenshot)

--------------------------------------------------------------------------------
-- Callbacks da NUI
--------------------------------------------------------------------------------

-- compat screenshot-basic
RegisterNUICallback('screenshot_created', function(body, cb)
    cb(true)
    local callback = body.id and captureCallbacks[body.id]
    if callback then
        captureCallbacks[body.id] = nil
        callback(body.data)
    end
end)

RegisterNUICallback('screenshot_upload_proxy', function(body, cb)
    cb(true)
    local token = body.id and uploadTokens[body.id]
    if token then
        uploadTokens[body.id] = nil
        if body.data then
            TriggerLatentServerEvent('screencapture:PerformUploadProxy', imagesBps, token, body.data)
        end
    end
end)

RegisterNUICallback('capture_screen', function(body, cb)
    cb(true)
    if body.uploadToken then
        TriggerLatentServerEvent('screencapture:capture-screen', imagesBps, body.uploadToken, body.data)
    end
end)

local STREAM_TIMEOUT = { ok = false, error = 'Timed out waiting for stream acknowledgement' }

RegisterNUICallback('capture_stream_chunk', function(body, cb)
    if not body.token or not body.data then
        return cb({ ok = false, error = 'Missing stream token or data' })
    end
    local event = 'screencapture:stream-chunk-nui'
    local responseEvent = ('%s:%s'):format(event, uuid())
    cb(awaitServer(responseEvent, function()
        TriggerLatentServerEvent(event, streamBps, responseEvent, body.token, body.data)
    end, STREAM_ACK_TIMEOUT, STREAM_TIMEOUT))
end)

RegisterNUICallback('capture_stream_finalize', function(body, cb)
    if not body.token then
        return cb({ ok = false, error = 'Missing stream token' })
    end
    local event = 'screencapture:stream-finalize-nui'
    local responseEvent = ('%s:%s'):format(event, uuid())
    cb(awaitServer(responseEvent, function()
        TriggerServerEvent(event, responseEvent, body.token)
    end, STREAM_ACK_TIMEOUT, STREAM_TIMEOUT))
end)

RegisterNUICallback('live_stream_status', function(body, cb)
    cb({ ok = true })
    TriggerServerEvent('screencapture:liveStream:status', body)
end)
