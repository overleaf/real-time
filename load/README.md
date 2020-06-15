# Usage

Install socket.io v2 and checkout the socket.io-client repo to apply patches:

```
git clone https://github.com/socketio/socket.io-client
cd socket.io-client
git checkout -b ol-load-testing
git am /path/to/this/directory/*.patch
```

### client

Configure the client with a JSON blob as the hash of the URI:

```
{"DEBUG":true,"IO_ENDPOINT":"http://127.0.0.1:8080","IO_PATH":"/socket.io","CLIENT_NUM":1000,"BATCH_SIZE":200,"BATCH_DELAY":10000,"COLOR":"blue"}
```
translates into:

```
http://127.0.0.1:8080/index.html#{%22DEBUG%22:true,%22IO_ENDPOINT%22:%22http://127.0.0.1:8080%22,%22IO_PATH%22:%22/socket.io%22,%22CLIENT_NUM%22:1000,%22BATCH_SIZE%22:200,%22BATCH_DELAY%22:10000,%22COLOR%22:%22blue%22}
```

Your browser will happily accept the plain JSON blob and escape it as needed.

### server

You will need to bump the limits of the node process, the simplest way is:

```
# Create a sudo shell, bump limits and step back down again.
$ sudo -E sh -c 'ulimit -n 50000 && sudo -u $SUDO_USER -- sh -c "ulimit -n && START_IO=1 START_BENCH=false SOCKET_IO_CLIENT_DEV=/path/to/socket.io-client/dist/socket.io.dev.js /path/to/node load.js"'
```
