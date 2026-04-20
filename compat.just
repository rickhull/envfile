set shell := ["bash", "-cu"]

# Report compat direction and status.
status:
  @printf 'compat: targeting systemd EnvironmentFile compatibility\n'
  @printf 'see compat/README.md\n'
