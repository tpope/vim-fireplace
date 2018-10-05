import vim


def fireplace_let(var, value):
    return vim.command("let " + var + " = " + nrepl_fireplace.vim_encode(value))


def fireplace_check():
    vim.eval("getchar(1)")


def fireplace_repl_dispatch(command, *args):
    try:
        fireplace_let(
            "out",
            nrepl_fireplace.dispatch(
                vim.eval("self.host"),
                vim.eval("self.port"),
                fireplace_check,
                None,
                command,
                *args
            ),
        )
    except Exception as e:
        fireplace_let("err", str(e))
