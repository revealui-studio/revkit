function revealfleet {
    [CmdletBinding()]
    param([string]$Sub = '', [string]$Distribution = 'Ubuntu')
    if ($Sub -in @('.', '..')) { throw 'Expected a single canonical fleet checkout name.' }
    foreach ($character in $Sub.ToCharArray()) {
        if (-not 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-'.Contains([string]$character)) {
            throw 'Expected a single canonical fleet checkout name.'
        }
    }
    $target = if ($Sub) { "~/revealfleet/$Sub" } else { '~/revealfleet' }
    # This function launches only when explicitly invoked by its owner.
    # Importing the module never changes the default distro or starts an agent.
    wsl.exe --distribution $Distribution --cd $target -- bash -lc claude
}
