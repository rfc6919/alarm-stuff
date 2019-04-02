local radio = require('radio')

local block = require('radio.core.block')
local types = require('radio.types')


---
-- High precision timestamp

local ffi = require("ffi")
ffi.cdef[[
  typedef long time_t;
  typedef struct timeval { time_t tv_sec; time_t tv_usec; } timeval;
  int gettimeofday(struct timeval* t, void* tzp);
]]

local function gettimeofday()
  local t = ffi.new("timeval")
  ffi.C.gettimeofday(t, nil)
  return tonumber(t.tv_sec) + tonumber(t.tv_usec)/1000000
end


---
-- bin/hex string conversion

local function frombin(str)
    return (str:gsub('........', function (bits)
        return string.char(tonumber(bits, 2))
    end))
end

local function tohex(str)
    return (str:gsub('.', function (c)
        return string.format('%02x', string.byte(c))
    end))
end


---
-- BitPacketType
-- generic bit packet type
--
-- {
--   timestamp = <number>,
--   payload = <string>,
--   crc = <string>,
-- }

local BitPacketType = types.ObjectType.factory()

function BitPacketType.new(timestamp, payload)
    local self = setmetatable({}, BitPacketType)
    self.timestamp = timestamp or gettimeofday()
    self.payload = payload or {}
    self.signal_strength = {}
    return self
end

local function dumb_crc(x)
    -- bodged from ax25_compute_crc
    local crc

    crc = 0xffff

    for i = 1, #x do
        if bit.bxor(bit.band(crc, 0x1), x[i] == "0" and 0 or 1) == 1 then
            crc = bit.bxor(bit.rshift(crc, 1), 0x8408)
        else
            crc = bit.rshift(crc, 1)
        end
    end

    crc = bit.band(bit.bnot(crc), 0xffff)

    return crc
end

function BitPacketType:finalize()
    local preamble = "1111010101010101010101010101010011111100"
    local preamble_length = preamble:len()
    self.crc = dumb_crc(self.payload)
    self.payload = table.concat(self.payload)
    if self.payload:sub(1,preamble_length) == preamble then
        local payload2 = {}
        local payload3 = ""
        for i = preamble_length+1, self.payload:len(), 3 do
            local symbol = self.payload:sub(i, i+2)
            if symbol == "110" then
                payload2[#payload2+1] = "1"
            elseif symbol == "100" then
                payload2[#payload2+1] = "0"
            elseif symbol == "1" then
                -- trailer symbol, ignore it
            else
                payload2[#payload2+1] = "_"
            end
        end
        self.payload2 = table.concat(payload2)
        if (self.payload2:len()%8 == 0) and (self.payload2:find("^[01]*$")) then
            self.payload3 = tohex(frombin(self.payload2))
        end
    end

    --table.sort(self.signal_strength)
    --self.signal_strength = self.signal_strength[#self.signal_strength-]
    local sum = 0
    local count = #self.signal_strength
    for i = 1, count do sum = sum + self.signal_strength[i] end
    self.signal_strength = sum / count
end

---
-- BitPacketDetectorBlock
-- from an input sequence of types.Bit, output a sequence of BitPacketType
-- packets are delimited by more than 10 space (0) symbols
--
-- first and last bits of a packet are always zero (since we ignore dead
-- air, and don't want to collect unneeded zero bits at the end of a packet)
--
-- so remember if we're currently processing a packet or not, and then:
-- when we receive a symbol
--   if it's a space
--     if we're not handling a packet already
--       we're idle, NOOP
--     otherwise
--       we're handling a packet, so remember we got a zero bit
--       if we got > 10 zero bits in a row
--         we're idle, emit the packet we've been building
--   otherwise (it's a mark)
--     if we're not already handling a packet
--       set up a new packet and push the "1" bit
--     otherwise
--       push the accumulated "0" bits
--       push the "1" bit

local BitPacketDetectorBlock = block.factory("BitPacketDetectorBlock")

BitPacketDetectorBlock.BitPacketType = BitPacketType

function BitPacketDetectorBlock:instantiate()
    self:add_type_signature(
        {block.Input("in", types.Bit), block.Input("signal_strength", types.Float32)},
        {block.Output("out", BitPacketType)}
    )
end

function BitPacketDetectorBlock:initialize()
    self.in_packet = false
    self.zero_bits = 0
    self.sample_number = 0
end

function BitPacketDetectorBlock:process(x, signal_strength)
    local out = BitPacketType.vector()

    for i = 0, x.length-1 do
        self.sample_number = self.sample_number + 1
        if x.data[i] == types.Bit(0) then
            if self.in_packet == false then
                -- idle, do nothing
            else
                -- perhaps in a packet, increment zero bit counter
                self.zero_bits = self.zero_bits + 1
                if self.zero_bits > 10 then
                    -- we're idle, emit the packet
                    self.packet:finalize()
                    out:append(self.packet)
                    self.in_packet = false
                    -- bail at the end of a heartbeat
                    -- if self.packet.crc == 49429 then os.exit() end
                end
                --table.insert(self.packet.signal_strength, tonumber(signal_strength.data[i].value))
            end
        else
            if self.in_packet == false then
                -- starting a new packet
                self.in_packet = true
                self.packet = BitPacketType.new()
                -- self.packet = BitPacketType.new(os.date("%F %T",self.sample_number/self:get_rate()))
            else
                -- already in a packet, flush accumulated zeros
                local j
                for j = 1, self.zero_bits do
                    self.packet.payload[#self.packet.payload+1] = "0"
                end
            end
            self.zero_bits = 0
            self.packet.payload[#self.packet.payload+1] = "1"
            table.insert(self.packet.signal_strength, tonumber(signal_strength.data[i].value))
        end
    end
    return out
end

---

local input_sample_rate = 4e6
local symbol_rate = 5000

--local source = radio.IQFileSource(io.stdin, 's8', input_sample_rate)
local source = radio.HackRFSource(433e6, input_sample_rate, {lna_gain = 24, vga_gain = 38})
local tuner = radio.TunerBlock(-915e3, 10e3, input_sample_rate/symbol_rate/8) -- want ~8 samples/symbol
local amplitude = radio.ComplexMagnitudeBlock()
local shift = radio.AddConstantBlock(-0.1) -- FIXME use a real AGC
local clock_recoverer = radio.ZeroCrossingClockRecoveryBlock(symbol_rate)
local sampler_data = radio.SamplerBlock()
local sampler_strength = radio.SamplerBlock()
local slicer = radio.SlicerBlock()
local packetizer = BitPacketDetectorBlock()
local output = radio.JSONSink()

local top = radio.CompositeBlock()

top:connect(source, tuner, amplitude, shift, sampler_data, slicer, packetizer, output)
top:connect(shift, 'out', clock_recoverer, 'in')
top:connect(clock_recoverer, 'out', sampler_data, 'clock')
top:connect(amplitude, 'out', sampler_strength, 'data')
top:connect(clock_recoverer, 'out', sampler_strength, 'clock')
top:connect(sampler_strength, 'out', packetizer, 'signal_strength')

top:run()
