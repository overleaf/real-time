### Usage

Install socket.io v2

```
$ npm install socket.io@2
```

### server

```
# start the demo server on port IO_SERVER_PORT=8080
$ START_IO=1 START_BENCH=false /path/to/node load.js
```

### client

Open `http://127.0.0.1:8080/` in your browser.

Optionally configure the client with a JSON blob as the hash of the URI.
> Note: The demo page will pre-populate the blob with defaults that trigger
>        the parse-error/leak reproducibly.

- `IO_ENDPOINT` custom origin for the demo server
- `IO_PATH` `/socket.io` path component of the demo server
- `COLOR` an optional marker for requests (e.g. blue vs green for two tabs)
- `CLIENT_NUM` total number of clients to create
- `BATCH_SIZE` number of clients to create in a single before ...
- `BATCH_DELAY` (in ms) ...detaching to allow clients to process their tests
- `DEBUG` enable/disable logging statements

### pushing limits

Running the load test with multiple clients might require increasing the
 resource limits of the node process, namely the number of open files.

Here is a simple way to do this:

```
# Create a sudo shell, bump limits and step back down again.
$ sudo -E sh -c 'ulimit -n 50000 && sudo -u $SUDO_USER -- sh -c "ulimit -n && START_IO=1 START_BENCH=false SOCKET_IO_CLIENT_DEV=/path/to/socket.io-client/dist/socket.io.dev.js /path/to/node load.js"'
```


### Custom client

Checkout the socket.io-client repo to apply patches:

```
git clone https://github.com/socketio/socket.io-client
cd socket.io-client
git checkout -b ol-load-testing
git am /path/to/this/directory/*.patch

# restart the server with the following additional environment variable set
$ SOCKET_IO_CLIENT_DEV=/path/to/socket.io-client/dist/socket.io.dev.js ...
```
