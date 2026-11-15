type: Changed

**The system connects to the server**: requests, the event stream and the sockets go through WinHTTP on Windows and libcurl on Linux, with the system's proxy and certificates. On Linux, libcurl is needed at run time. A stopped connection ends within a second.
