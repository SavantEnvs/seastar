// libFuzzer harness for the chunked-transfer-encoding parsers in src/http/chunk_parsers.rl:
// the chunk-size line with extensions (http_chunk_size_and_ext_parser) and the trailer headers
// (http_chunk_trailer_parser). Both get the same bytes, so one corpus covers each.
#include "http_fuzz_common.hh"

#include <seastar/http/chunk_parsers.hh>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) {
        return -1;
    }
    size_t n = 0;
    {
        seastar::http_chunk_size_and_ext_parser parser;
        parser.init();
        mayhem::feed(parser, data + 1, size - 1, data[0]);
        if (!parser.failed() && !parser.eof()) {
            n += parser.get_size().size();
            for (auto& e : parser.get_parsed_extensions()) {
                n += e.first.size() + e.second.size();
            }
        }
    }
    {
        seastar::http_chunk_trailer_parser parser;
        parser.init();
        mayhem::feed(parser, data + 1, size - 1, data[0]);
        if (!parser.failed() && !parser.eof()) {
            for (auto& h : parser.get_parsed_headers()) {
                n += h.first.size() + h.second.size();
            }
        }
    }
    return n == size_t(-1);
}
