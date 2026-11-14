type: Fixed

**Slash commands are listed again**: when opencode native started with the server, it read the server's commands before the server had them all, and kept that empty list until it was restarted: / in the composer and the palette listed nothing. The commands, the agents and the models are now read again each time their list opens.
