# Nexaloid Go

Go bindings for the Nexaloid Chinese tokenizer.

## Install

```bash
go get github.com/nexaloid/nexaloid-go/nexaloid
```

## Usage

```go
package main

import (
	"fmt"
	"log"

	"github.com/nexaloid/nexaloid-go/nexaloid"
)

func main() {
	tokenizer, err := nexaloid.New("data/dict/nexaloid.nxdict")
	if err != nil {
		log.Fatal(err)
	}
	defer tokenizer.Close()

	tokens, err := tokenizer.Tokenize("昨日中概股集体跌超百分之五", nexaloid.Search)
	if err != nil {
		log.Fatal(err)
	}
	for _, token := range tokens {
		fmt.Printf("%s source=%s flags=%d\n", token.Text, token.Source, token.Flags)
	}
}
```

## Token Contract

`Search` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `RecallSearch` also adds explicit lattice candidates.

`Token.Source` uses the public `Source` type and its `String()` method returns the stable name. `Token.CustomRuleIndex()` returns the custom rule's 1-based JSON array index when the token came from `SourceRule` and `Flags` is nonzero.

## Development

```powershell
cd bindings/go
$env:PATH = "$PWD\..\..\core\zig-out\bin;$env:PATH"
go test ./...
```
