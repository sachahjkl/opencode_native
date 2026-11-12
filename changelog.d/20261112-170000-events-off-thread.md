type: Changed

**Server events are read off the interface**: each event of the server is read on its stream's thread, so a burst of deltas costs the interface only what applying them costs. An event that changes nothing a window shows (a delta of a session not shown) no longer redraws the detached windows. What cannot be read (an event, an answer, a queued prompt) is counted and logged once per kind; the status bar shows the count beside the frame rate.
