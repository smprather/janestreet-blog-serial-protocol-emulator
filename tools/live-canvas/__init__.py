"""Live Canvas — agent-side surface.

The plugin's real surface is the dashboard pane (`dashboard/`). There are no
agent tools or hooks yet: the publish path is the filesystem, which every agent
already has. `register` stays as a no-op so the general plugin loader treats
this as a well-formed plugin.
"""


def register(ctx):  # noqa: ARG001 - plugin loader contract
    """Nothing to register agent-side (deliberately)."""
    return None
