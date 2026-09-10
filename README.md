# ZXDB

ZXDB is an esxDOS dot command for ZX Spectrum computers equipped with [DivTiesus](https://www.zxprojects.com/divtiesus/). It searches the [ZXDB](https://spectrumcomputing.co.uk/) database through the HTTP API provided by [Remy Sharp](https://zxdb.remysharp.com/) and downloads the selected game directly to the SD card over the DivTiesus ESP8266 Wi-Fi interface.

## Features

- Search [ZXDB](https://spectrumcomputing.co.uk/) for ZX Spectrum games by title.
- Display up to ten search results.
- Show the game title, year, file type and 48K/128K model when available.
- Download TAP, TZX, Z80 and other supported file formats.
- Show the current Wi-Fi status, SSID, IP address and MAC address.
- Attempt to reconnect the DivTiesus ESP8266 automatically if the Wi-Fi connection has been lost.

## Requirements

- A ZX Spectrum compatible with DivTiesus.
- An SD card with esxDOS.
- A [DivTiesus](https://www.zxprojects.com/divtiesus/) DivMMC with its ESP8266 Wi-Fi module.
- [sjasmplus](https://github.com/z00m128/sjasmplus) to compile the source code.

ZXDB communicates directly with the DivTiesus UART through ports `$FC3B` and `$FD3B`. Compatibility with other esxDOS or ESP8266 devices is not currently guaranteed.

## Project structure

The repository is organised as follows:

```text
ZXDB-esxDOS-Command/
├── .vscode/
│   └── tasks.json
├── bin/
│   └── ZXDB
├── src/
│   └── ZXDB.asm
└── README.md
```

The `src` directory contains the Z80 assembly source code. The compiled esxDOS dot command is written to `bin/ZXDB`. The `bin` directory must exist before compiling.

## Compiling

From the root of the repository, change to the `src` directory and run:

```bash
cd src
sjasmplus ZXDB.asm --nologo
```

The `OUTPUT "../bin/ZXDB"` directive in `ZXDB.asm` produces a binary file named `ZXDB`, without an extension, inside the `bin` directory. This is the esxDOS dot command; `src/ZXDB.asm` is only the source file.

If `sjasmplus` is not available from the command line, add its directory to your system `PATH` or run it using its complete path.

### Compiling with Visual Studio Code

Visual Studio Code can run `sjasmplus` through a build task:

1. Open the root folder of the repository in Visual Studio Code.
2. Create a folder named `.vscode` in the root of the project.
3. Inside `.vscode`, create a file named `tasks.json`.
4. Add the following configuration:

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Compilar Dot Command esxDOS",
            "type": "shell",
            "command": "C:/Tools/sjasmplus/sjasmplus.exe",
            "args": [
                "${fileBasename}",
                "--nologo"
            ],
            "options": {
                "cwd": "${fileDirname}"
            },
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "problemMatcher": []
        }
    ]
}
```

The example path `C:/Tools/sjasmplus/sjasmplus.exe` is fictitious. Replace it with the location of `sjasmplus.exe` on your computer.

The file must be stored at this location relative to the project folder:

```text
.vscode/tasks.json
```

Open `src/ZXDB.asm` in the editor and press `Ctrl+Shift+B`, or select **Terminal > Run Build Task**. Because `${fileDirname}` is used as the working directory, Visual Studio Code runs the assembler from `src`. The `OUTPUT "../bin/ZXDB"` directive then creates or replaces `bin/ZXDB`.

Do not add a `--raw` argument to `tasks.json`. Combining `--raw` with the `OUTPUT` directive may generate an additional binary in `src` or attempt to produce the same output twice.

## Installing

Copy the compiled `bin/ZXDB` file—not `src/ZXDB.asm`—to the `BIN` directory on the esxDOS SD card:

```text
/BIN/ZXDB
```

The resulting SD card structure should include:

```text
BIN/
└── ZXDB
```

Safely eject the card from your computer. With the ZX Spectrum switched off and unplugged from the mains, insert the card into the SD or microSD card slot of the DivTiesus connected to the ZX Spectrum. Reconnect the power and switch on the computer. Once esxDOS is running, configure the DivTiesus Wi-Fi connection with its `.wconf` utility if it has not already been configured. The command can then be executed as `.ZXDB` from BASIC.

## Usage

```text
.ZXDB -h
.ZXDB -i
.ZXDB -s "game name"
```

### Help

```text
.ZXDB -h
```

Displays the command help and a summary of the available options.

### Network information

```text
.ZXDB -i
```

Displays information similar to:

```text
Network status: Connected
SSID: MyNetwork
IP: 192.168.1.45
MAC: 24:d7:eb:c8:xx:xx
```

If the connection has been lost, ZXDB asks the DivTiesus ESP8266 to reconnect using its stored Wi-Fi credentials. If Wi-Fi has not been configured, use the DivTiesus configuration utility:

```text
.wconf
```

### Searching and downloading

The game name is required and must be separated from `-s` by a space:

```text
.ZXDB -s "fernando"
```

Another example:

```text
.ZXDB -s "target renegade"
```

Spaces in the search text are converted to the format expected by the ZXDB API. Quotation marks are recommended for titles containing spaces.

ZXDB displays a maximum of ten numbered results. If the search term is too broad, the desired game or a particular file format may not be shown, even if it exists in the database, because only the first ten matches are displayed. In that case, narrow the search by entering more of the game's title. For example, instead of searching for:

```text
.ZXDB -s "Indiana Jones"
```

narrow the search to:

```text
.ZXDB -s "Indiana Jones and the Temple"
```

This more specific search reduces unrelated matches and allows the available file formats for *Indiana Jones and the Temple of Doom* to appear within the ten displayed results.

A result may look like:

```text
(1) Target Renegade [128] [TZX] (1988)
(2) Target Renegade [TAP] (1988)
```

Long titles can occupy two lines. The continuation is indented below the beginning of the title:

```text
(1) Indiana Jones and the Temple
    of Doom [TZX] (1987)
```

Press the number shown next to a result to download it. Numbers `1` to `9` select the first nine results and `0` selects the tenth result. Press BREAK to cancel without downloading anything.

During a download, ZXDB displays the destination filename and updates the percentage one point at a time:

```text
Saving: TARGETRE.TZX
Progress: 57%
```

Downloaded files are saved in the current esxDOS directory. Since esxDOS uses 8.3 filenames, long source names are shortened. If the destination filename already exists, ZXDB changes the final character of the base name to a number so that the existing file is not overwritten.

**Important:** DivTiesus is not compatible with the `.tzx` format. Only games in `.tap`, `.z80`, `.sna` and `.rom` formats can be executed directly with DivTiesus.

## Typical workflow

1. Configure the DivTiesus Wi-Fi connection with `.wconf` if necessary.
2. Check the connection with `.ZXDB -i`.
3. Search for a game with `.ZXDB -s "game name"`.
4. Press the number corresponding to the desired result.
5. Wait until the progress reaches 100% and `Download completed` is displayed.

## Troubleshooting

### `Error: No WIFI network. Run .wconf`

The DivTiesus ESP8266 has no usable Wi-Fi connection. Configure the network with the DivTiesus `.wconf` utility and try again. If it was previously configured, make sure the access point is available; ZXDB will attempt an automatic reconnection.

### `Error: UART doesn't respond`

ZXDB cannot communicate with the DivTiesus ESP8266. Check that DivTiesus is connected correctly and that its Wi-Fi module is powered and operational.

### `Error: cannot connect to zxdb.remysharp.com`

The Wi-Fi connection may be active, but the HTTP server could not be reached. Check Internet access and try again later.

### `Error: CIPSEND`

The ESP8266 did not accept the HTTP request. This can occur if the TCP connection was closed or the Wi-Fi connection was interrupted.

### `Error: invalid HTTP response`

The received data did not contain a valid successful HTTP response. Retry the search and verify that the API is reachable.

### `Error saving to SD card`

Check that the SD card is writable, has free space and is correctly mounted by esxDOS.

## Credits

Thanks to [Remy Sharp](https://github.com/remy/zxdb-specnext-api) for the ZXDB API used by this project.

Thanks to [ZX Projects - DivTiesus](https://www.zxprojects.com/divtiesus/) for its DIVMMC esxDOS-compatible with ESP8266 Wi-Fi interface.

ZX-Uno UART register definitions are compatible with [netman-zx by Alex N.](https://github.com/nihirash/netman-zx).
