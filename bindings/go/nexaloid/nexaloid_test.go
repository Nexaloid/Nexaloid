package nexaloid

import "testing"

func TestTokenize(t *testing.T) {
	tokenizer, err := New("../../../data/dict/nexaloid.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer tokenizer.Close()

	tokens, err := tokenizer.Tokenize("南京市长江大桥", Accurate)
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 2 {
		t.Fatalf("expected 2 tokens, got %d: %#v", len(tokens), tokens)
	}
	if tokens[0].Text != "南京市" || tokens[1].Text != "长江大桥" {
		t.Fatalf("unexpected tokens: %#v", tokens)
	}
}
