// libFuzzer harness for seastar::http_request_parser (src/http/request_parser.rl), plus
// request::parse_query_param() on whatever it parses. Byte 1 selects the size limit
// (0 = unlimited, else 4*byte) so the too_large paths are reachable.
#include "http_fuzz_common.hh"

#include <seastar/http/request.hh>
#include <seastar/http/request_parser.hh>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 2) {
        return -1;
    }
    seastar::http_request_parser parser;
    parser.init();
    if (data[1]) {
        parser.set_size_limit(size_t(data[1]) * 4);
    }
    mayhem::feed(parser, data + 2, size - 2, data[0]);
    if (parser.failed()) {
        (void)parser.size_limit_exceeded();
        (void)parser.uri_too_large();
    } else if (!parser.eof()) {
        auto req = parser.get_parsed_request();
        size_t n = req->_method.size() + req->_version.size();
        for (auto& h : req->_headers) {
            n += h.first.size() + h.second.size();
        }
        n += req->parse_query_param().size();
        return n == size_t(-1);
    }
    return 0;
}
