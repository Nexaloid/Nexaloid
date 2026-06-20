#include <iostream>

#include <nexaloid.hpp>

int main() {
    NxConfig config{};
    config.dict_path = "data/dict/nexaloid.tsv";

    nexaloid::Tokenizer tokenizer(config);
    for (const auto& word : tokenizer.cut("南京市长江大桥")) {
        std::cout << word << "\n";
    }
    return 0;
}

