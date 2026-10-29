// libFuzzer harness for seastar::http_response_parser (src/http/response_parser.rl).
#include "http_fuzz_common.hh"

#include <seastar/http/reply.hh>
#include <seastar/http/response_parser.hh>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) {
        return -1;
    }
    seastar::http_response_parser parser;
    parser.init();
    mayhem::feed(parser, data + 1, size - 1, data[0]);
    if (parser.failed()) {
        return parser.error_message().empty() ? 1 : 0;
    }
    if (!parser.eof()) {
        auto rsp = parser.get_parsed_response();
        size_t n = rsp->_version.size() + size_t(rsp->_status);
        for (auto& h : rsp->_headers) {
            n += h.first.size() + h.second.size();
        }
        return n == size_t(-1);
    }
    return 0;
}
