#pragma once

#include <exception>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "nexaloid.h"

namespace nexaloid {

enum class Mode {
    Accurate = NX_MODE_ACCURATE,
    Full = NX_MODE_FULL,
    Search = NX_MODE_SEARCH,
    RecallSearch = NX_MODE_RECALL_SEARCH,
};

enum class Source : uint16_t {
    BaseDict = NX_SOURCE_BASE_DICT,
    UserDict = NX_SOURCE_USER_DICT,
    DomainDict = NX_SOURCE_DOMAIN_DICT,
    Rule = NX_SOURCE_RULE,
    Unknown = NX_SOURCE_UNKNOWN,
    Plugin = NX_SOURCE_PLUGIN,
};

inline const char* source_name(Source source) noexcept {
    switch (source) {
    case Source::BaseDict: return "base_dict";
    case Source::UserDict: return "user_dict";
    case Source::DomainDict: return "domain_dict";
    case Source::Rule: return "rule";
    case Source::Unknown: return "unknown";
    case Source::Plugin: return "plugin";
    default: return "unrecognized";
    }
}

struct Token {
    std::string text;
    uint32_t start_byte;
    uint32_t end_byte;
    uint32_t start_char;
    uint32_t end_char;
    uint32_t word_id;
    uint16_t pos_id;
    Source source;
    uint16_t flags;
    float score;
};

class Error : public std::runtime_error {
public:
    explicit Error(NxStatus status)
        : std::runtime_error(nx_status_message(status)), status_(status) {}

    NxStatus status() const { return status_; }

private:
    NxStatus status_;
};

class Tokenizer {
public:
    explicit Tokenizer(const NxConfig& config = {}) {
        NxStatus status = nx_engine_new(&config, &engine_);
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    ~Tokenizer() {
        nx_engine_free(engine_);
    }

    // The wrapper owns exactly one native engine handle; copying would double-free it.
    Tokenizer(const Tokenizer&) = delete;
    Tokenizer& operator=(const Tokenizer&) = delete;

    Tokenizer(Tokenizer&& other) noexcept : engine_(other.engine_) {
        other.engine_ = nullptr;
    }

    Tokenizer& operator=(Tokenizer&& other) noexcept {
        if (this != &other) {
            nx_engine_free(engine_);
            engine_ = other.engine_;
            other.engine_ = nullptr;
        }
        return *this;
    }

    void add_word(std::string_view word, float score = 10.0f, uint16_t pos_id = 0) {
        NxStatus status = nx_add_word(engine_, word.data(), word.size(), 0, score, pos_id);
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    void load_userdict(const char* path) {
        NxStatus status = nx_reload_user_dict(engine_, path);
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    void load_plugin(const char* path, const char* config_json = nullptr) {
        NxStatus status = nx_load_plugin(engine_, path, config_json);
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    void load_rules_json(std::string_view json) {
        NxStatus status = nx_load_rules_json(engine_, json.data(), json.size());
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    void load_rules(const char* path) {
        std::ifstream file(path);
        if (!file) {
            throw std::runtime_error("failed to open rules file");
        }
        std::string json((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        load_rules_json(json);
    }

    void clear_rules() {
        NxStatus status = nx_clear_rules(engine_);
        if (status != NX_OK) {
            throw Error(status);
        }
    }

    std::vector<Token> tokenize(std::string_view text, Mode mode = Mode::Accurate) {
        std::vector<Token> out;
        CallbackData data{&out, nullptr};
        // C ABI callbacks are synchronous, so stack-owned CallbackData is safe here.
        NxStatus status = nx_tokenize(
            engine_,
            text.data(),
            text.size(),
            static_cast<NxMode>(mode),
            &Tokenizer::on_token,
            &data);
        if (data.exception) {
            std::rethrow_exception(data.exception);
        }
        if (status != NX_OK) {
            throw Error(status);
        }
        return out;
    }

    std::vector<std::string> cut(std::string_view text, Mode mode = Mode::Accurate) {
        std::vector<std::string> out;
        for (const auto& token : tokenize(text, mode)) {
            out.push_back(token.text);
        }
        return out;
    }

private:
    struct CallbackData {
        std::vector<Token>* out;
        std::exception_ptr exception;
    };

    static void on_token(const NxToken* token, const char* text, size_t, void* user_data) noexcept {
        auto* data = static_cast<CallbackData*>(user_data);
        if (data->exception) {
            return;
        }
        // Copy token text immediately; the callback text pointer belongs to the native call frame.
        try {
            data->out->push_back(Token{
                std::string(text + token->start_byte, text + token->end_byte),
                token->start_byte,
                token->end_byte,
                token->start_char,
                token->end_char,
                token->word_id,
                token->pos_id,
                static_cast<Source>(token->source),
                token->flags,
                token->score,
            });
        } catch (...) {
            data->exception = std::current_exception();
        }
    }

    NxEngine* engine_ = nullptr;
};

} // namespace nexaloid
