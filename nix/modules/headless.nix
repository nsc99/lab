{ ... }:

{
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    KillUserProcesses = false;
  };
}
