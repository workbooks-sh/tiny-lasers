package main

import (
	"fmt"
	"os"
	"sort"
)

func main() {
	v := []int{5, 3, 8, 1, 9, 2}
	sort.Ints(v)
	sum := 0
	for _, x := range v {
		sum += x
	}
	fmt.Printf("sorted: %v sum=%d\n", v, sum)
	if sum == 28 {
		os.Exit(42)
	}
	os.Exit(1)
}
