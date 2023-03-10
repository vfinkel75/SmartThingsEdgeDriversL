--  Copyright 2021 SmartThings
--
--  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
--  except in compliance with the License. You may obtain a copy of the License at:
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software distributed under the
--  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
--  either express or implied. See the License for the specific language governing permissions
--  and limitations under the License.
--

local FrameHeader = require "lustre.frame.frame_header"
local OpCode = require "lustre.frame.opcode"
local CloseFrame = require"lustre.frame.close".CloseFrame

local Frame = {}
Frame.__index = Frame

Frame.MAX_CONTROL_FRAME_LENGTH = 125

function Frame.from_stream(socket)
  local header, err = FrameHeader.from_stream(socket)
  if not header then return nil, err end
  local payload
  if header.length > 0 then
    -- TODO receive in chunks if header.length is too big
    payload, err, _ = socket:receive(header.length) -- num bytes
    if not payload then
      return nil, err -- TODO return partial frame
    end
  else
    payload = ""
  end

  if header.opcode.sub == "reserved" then return nil, "invalid opcode" end
  if header.rsv1 or header.rsv2 or header.rsv3 then
    -- These bits can be used if an extension has been negotiated, but
    -- extension support for the lib is not yet functionally tested.
    return nil, "invalid rsv bit"
  end
  return Frame.from_parts(header, payload, header:is_masked())
end

function Frame.decode(bytes)
  local header, err = FrameHeader.decode(bytes)
  if not header then return nil, err end
  return Frame.from_parts(header, string.sub(bytes, header:len() + 1), header:is_masked())
end

function Frame.ping(payload)
  return Frame.from_parts(FrameHeader.default():set_length(#(payload or "")):set_opcode(
                            OpCode.ping()), payload or "")
end

function Frame.pong(payload)
  local fm = Frame.from_parts(FrameHeader.default():set_length(#(payload or "")):set_opcode(
                                OpCode.pong()), payload or "")
  return fm
end

function Frame.close(close_code, reason)
  local payload = ""
  if close_code then payload = payload .. CloseFrame.from_parts(close_code, reason):encode() end
  return Frame.from_parts(FrameHeader.default(), payload)
end

function Frame.from_parts(header, payload, apply_mask)
  if apply_mask then
    local fm = setmetatable({
      header = header,
      payload = payload,
      _masked_payload = true,
    }, Frame)
    fm:apply_mask()
    return fm
  else
    return setmetatable({
      header = header,
      payload = payload,
      _masked_payload = false,
    }, Frame)

  end
end

function Frame:len() return self.header:len() + self.header:payload_len() end

function Frame:payload_len() return self.header:payload_len() end

function Frame:payload_is_masked() return self._masked_payload end

function Frame:is_final() return self.header.fin end

function Frame:is_control() return self.header.opcode.type == "control" end

local seeded = false
local function seed_once()
  if seeded then return end
  seeded = true
  math.randomseed(os.time())
end

local function generate_mask()
  seed_once()
  local bytes = {}
  for _ = 1, 4 do table.insert(bytes, math.random(0, 255)) end
  return bytes
end

function Frame:set_mask(mask)
  mask = mask or generate_mask()
  self.header:set_mask(mask)
  return self
end

---Apply the mask array from the header, for outbound
---client messages, this will mask the payload, for inbound
---client messages, this will unmask the payload.
---
---note: this applies the mask in place
function Frame:apply_mask()
  if not self.header.mask then return nil, "No mask to apply" end
  local unmasked = ""
  for i = 0, #self.payload - 1 do
    local byte = string.byte(self.payload, i + 1, i + 1)
    local char = byte ~ self.header.mask[(i % 4) + 1]
    unmasked = unmasked .. string.char(char)
  end
  self.payload = unmasked
  self._masked_payload = not self._masked_payload
end

function Frame:encode()
  local ret = self.header:encode()
  if not self:payload_is_masked() then
    self:apply_mask()
    ret = ret .. self.payload
    self:apply_mask() -- undo masking
  else
    ret = ret .. self.payload
  end

  return ret
end

return Frame
