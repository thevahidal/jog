//! Emits the shell hook that calls `jog _entered` on directory change, so a
//! repo's briefing pops up the first time you cd into it each day.

const zsh_hook =
    \\# jog shell integration (zsh) — add to ~/.zshrc:  eval "$(jog shell-init zsh)"
    \\_jog_chpwd() { command jog _entered "$PWD" 2>/dev/null }
    \\autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd _jog_chpwd
    \\_jog_chpwd
    \\
;

const bash_hook =
    \\# jog shell integration (bash) — add to ~/.bashrc:  eval "$(jog shell-init bash)"
    \\_jog_last_pwd=""
    \\_jog_prompt() {
    \\  if [ "$PWD" != "$_jog_last_pwd" ]; then
    \\    _jog_last_pwd="$PWD"
    \\    command jog _entered "$PWD" 2>/dev/null
    \\  fi
    \\}
    \\case "$PROMPT_COMMAND" in
    \\  *_jog_prompt*) ;;
    \\  *) PROMPT_COMMAND="_jog_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    \\esac
    \\
;

pub fn hookFor(shell: []const u8) ?[]const u8 {
    const std = @import("std");
    if (std.mem.eql(u8, shell, "zsh")) return zsh_hook;
    if (std.mem.eql(u8, shell, "bash")) return bash_hook;
    return null;
}
