// Shared helper for the Seastar HTTP parser harnesses.
//
// Input layout: byte 0 is the chunk stride (0 = hand the whole message over as one
// temporary_buffer, N = split it into N-byte buffers, which exercises the parsers'
// scattered-buffer paths); the rest is the message. The parsers are plain ragel state
// machines that return ready futures, so no reactor is needed.
#pragma once

#include <seastar/core/future.hh>
#include <seastar/core/iostream.hh>
#include <seastar/core/temporary_buffer.hh>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <variant>

namespace mayhem {

// Feeds [data, data+size) to the parser the way a connection does: buffer by buffer until it
// stops consuming, then an empty buffer for EOF. Returns true if the parser stopped on its own.
template <typename Parser>
bool feed(Parser& parser, const uint8_t* data, size_t size, size_t stride) {
    size_t off = 0;
    while (off < size) {
        size_t len = stride ? std::min(stride, size - off) : size - off;
        bool stopped = std::holds_alternative<seastar::stop_consuming<char>>(
                parser(seastar::temporary_buffer<char>(reinterpret_cast<const char*>(data + off), len)).get().get());
        off += len;
        if (stopped) {
            return true;
        }
    }
    parser(seastar::temporary_buffer<char>()).get();
    return false;
}

} // namespace mayhem
