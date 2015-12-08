# fireplace.vim

There's a REPL in fireplace, but you probably wouldn't have noticed if I hadn't
told you.  Such is the way with fireplace.vim.  By the way, this plugin is for
Clojure.

## Installation

First, set up [cider-nrepl][].  (If you skip this step, fireplace.vim will
make do with eval, which mostly works.) Next, fireplace.vim doesn't provide
indenting or syntax highlighting, so you'll want [a set of Clojure runtime
files](https://github.com/guns/vim-clojure-static) if you're on a version of
Vim earlier than 7.4.  You might also want [salve.vim][] for assorted
static project support.

If you don't have a preferred installation method, I recommend
installing [pathogen.vim](https://github.com/tpope/vim-pathogen), and
then simply copy and paste:

    cd ~/.vim/bundle
    git clone git://github.com/tpope/vim-fireplace.git

Once help tags have been generated, you can view the manual with
`:help fireplace`.

## Features

This list isn't exhaustive; see the `:help` for details.

### Transparent setup

Fireplace.vim talks to nREPL.  With Leiningen, it connects automatically based
on `.nrepl-port`, otherwise it's just a `:Connect` away.  You can connect to
multiple instances of nREPL for different projects, and it will use the right
one automatically.  ClojureScript support is just as seamless with
[Piggieback][].

The only external dependency is that you have either a Vim with Python support
compiled in, or `python` in your path.

Oh, and if you don't have an nREPL connection, installing [salve.vim][]
lets it fall back to using `java clojure.main` for some of the basics, using a
class path based on your Leiningen config.  It's a bit slow, but a two-second
delay is vastly preferable to being forced out of my flow for a single
command, in my book.

[cider-nrepl]: https://github.com/clojure-emacs/cider-nrepl
[Piggieback]: https://github.com/cemerick/piggieback
[classpath.vim]: https://github.com/tpope/vim-classpath
[salve.vim]: https://github.com/tpope/vim-salve

### Not quite a REPL

You know that one plugin that provides a REPL in a split window and works
absolutely flawlessly, never breaking just because you did something innocuous
like backspace through part of the prompt?  No?  Such a shame, you really
would have liked it.

I've taken a different approach in fireplace.vim.  `cq`  (Think "Clojure
Quasi-REPL") is the prefix for a set of commands that bring up a *command-line
window* — the same thing you get when you hit `q:` — but set up for Clojure
code.

`cqq` prepopulates the command-line window with the expression under the
cursor.  `cqc` gives you a blank line in insert mode.

### Evaluating from the buffer

Standard stuff here.  `:Eval` evaluates a range (`:%Eval` gets the whole
file), `:Require` requires a namespace with `:reload` (`:Require!` does
`:reload-all`), either the current buffer or a given argument.  `:RunTests`
kicks off `(clojure.test/run-tests)` and loads the results into the quickfix
list.

There's a `cp` operator that evaluates a given motion (`cpp` for the
innermost form under the cursor). `cm` and `c1m` are similar, but they only
run `clojure.walk/macroexpand-all` and `macroexpand-1` instead of evaluating
the form entirely.

Any failed evaluation loads the stack trace into the location list, which
can be easily accessed with `:lopen`.

### Navigating and Comprehending

I was brand new to Clojure when I started this plugin, so stuff that helped me
understand code was a top priority.

* `:Source`, `:Doc`, and `:FindDoc`, which map to the underlying
  `clojure.repl` macro (with tab complete, of course).

* `K` is mapped to look up the symbol under the cursor with `doc`.

* `[d` is mapped to look up the symbol under the cursor with `source`.

* `[<C-D>` jumps to the definition of a symbol (even if it's inside a jar
  file).

* `gf`, everybody's favorite "go to file" command, works on namespaces.

Where possible, I favor enhancing built-ins over inventing a bunch of
`<Leader>` maps.

### Omnicomplete

Because why not?  It works in the quasi-REPL too.

## FAQ

> Why does it take so long for Vim to startup?

That's either [classpath.vim][] or [salve.vim][].

## Self-Promotion

Like fireplace.vim? Follow the repository on
[GitHub](https://github.com/tpope/vim-fireplace) and vote for it on
[vim.org](http://www.vim.org/scripts/script.php?script_id=4978).  And if
you're feeling especially charitable, follow [tpope](http://tpo.pe/) on
[Twitter](http://twitter.com/tpope) and
[GitHub](https://github.com/tpope).

## License

Copyright © Tim Pope.  Distributed under the same terms as Vim itself.
See `:help license`.
