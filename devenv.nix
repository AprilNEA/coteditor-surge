{ pkgs, ... }:
{
  packages = [ pkgs.ruff pkgs.nodejs ];
  languages.python.enable = true;
}
