// libFuzzer harness for url_decode / path_decode (include/seastar/http/url.hh), with a
// round-trip check against url_encode: decoding an encoded string must give it back.
#include <seastar/core/sstring.hh>
#include <seastar/http/url.hh>

#include <cstdint>
#include <cstdlib>
#include <string_view>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    std::string_view in(reinterpret_cast<const char*>(data), size);
    seastar::sstring url_out, path_out;
    if (!seastar::http::internal::url_decode(in, url_out) || !seastar::http::internal::path_decode(in, path_out)) {
        return 0;
    }
    // '+' only decodes to ' ' in url_decode; otherwise the two agree.
    if (in.find('+') == std::string_view::npos && url_out != path_out) {
        std::abort();
    }
    auto encoded = seastar::http::internal::url_encode(in);
    seastar::sstring round_url, round_path;
    seastar::http::internal::url_decode(encoded, round_url);
    seastar::http::internal::path_decode(encoded, round_path);
    if (std::string_view(round_url) != in || std::string_view(round_path) != in) {
        std::abort();
    }
    return 0;
}
