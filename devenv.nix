{ pkgs, ... }:
{
  packages = [ pkgs.shellcheck pkgs.shfmt pkgs.actionlint pkgs.nodejs ];
}
