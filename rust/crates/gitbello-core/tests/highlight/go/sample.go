// Package store keeps items.
package store

import (
	"errors"
	"fmt"
)

/* Block comment */
type Item struct {
	Name  string `json:"name"`
	Count int
}

var ErrEmpty = errors.New("empty")

func (s *Store) Add(item Item) error {
	if item.Count <= 0 {
		return ErrEmpty
	}
	ch := make(chan int, 10)
	defer close(ch)
	go func() { ch <- 0x1F }()
	r := 'r'
	fmt.Printf("%s: %d %c %v\n", item.Name, item.Count, r, 1.5e3)
	for i := range s.items {
		_ = i
	}
	return nil
}
var usage = `usage: tool [flags]
  -v "verbose"`
