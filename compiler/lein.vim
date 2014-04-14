" Vim compiler file

if exists("current_compiler")
  finish
endif
let current_compiler = "lein"

CompilerSet makeprg=lein
CompilerSet errorformat=%+G
