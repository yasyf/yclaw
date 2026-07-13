# Scratch-only overlay for the hermes-image-scratch validation build: a known root password so a
# throwaway tart VM can be logged into and inspected. Never in hermesModules, never built or
# published by CI (flake.nix builds only hermes-image), so this password never leaves a dev box.
{ ... }:
{
  users.users.root.initialPassword = "scratch";
}
