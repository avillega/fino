Fino is a programming language to explore Data Oriented Design (DOD) ideas
applied to the different stages of the compiler pipeline, and play with the
idea of mutable value semantics (MVS) in an interpreted, dynamically typed
programming language.

=== DOD ===
The plan is to explore DOD in all stages of the compiler pipeline, the current
state of it is as follows:

- Lexer: very simple lexer that uses zig's labeled switch to implement the
lexer state machine. some reduction in Token size by storing indexes to the
start and end of a lexeme instead of slices to the original source.

- Parser: this is where most of the exploration has happened. There are four
different implementations of the parser, forest_pointer, index_sea, post_tree
and moar_smaller. Each tries a different approach and builds on the previous
one's ideas to bring the AST memory footprint to a minimum.

-- forest_pointer: classic AST representation where nodes hold pointers to
other nodes. usages of arenas as the allocator to hold and free nodes.

-- index_sea: instead of pointers, nodes hold indexes into a vector of nodes.
This is close to the Zig parser approach.

-- post_tree: nodes hold no pointers or indexes, the structure of the tree is
an implicit tree in its post order representation. Node tag + payload ~ 8bytes

-- moar_smaller: the most aggressive representation. It also uses the post order
representation of the AST but uses a Struct of Arrays to store the nodes. each
node is represented by 5 bytes (ReleaseFast).

- Compiler: Mostly linear traversal of nodes in the post tree order

- Vm: Usage of Zig's labeled switch to implement a threaded interpreted.
Exploration of different instruction representations and allocation strategies
TBD.

=== MVS ===
Every object in the language is always passed by value to functions and copied
when a new variable is created and "references" another one. This could be
very inefficient, especially for big objects like arrays or structs (not yet impl)
the main optimizations are copy on write and mutate in place when the
reference count is equal to 1, keeping the semantics (illusion) of values being
moved around.

Other optimizations include moving values instead of copying them when it is a
known last use and crude runtime version of ownership/borrowing semantics (TBD)

=== Examples ===
Calculates and stores the first x Fibonacci numbers and prints them

```
fn fib(x) {
	var a = 0
	var b = 1
	var res = []

	var i = 0
	while i < x {
		res = append(res, a)
		var tmp = a + b
		a = b
		b = tmp
		i = i + 1
	}

	res = append(res, a)
	return res
}

var fibs = fib(20)

var i = 0
while i < len(fibs) {
	print("fib", i, ":", fibs[i])
	i = i+1
}
```

=== Run ===
- Compile with `zig build`, there are no dependencies other than Zig 0.16
- run `fino` without arguments to enter the repl
- run `fino {file}` to run the fino program in file


=== License ===
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

For more information, please refer to <https://unlicense.org/>
