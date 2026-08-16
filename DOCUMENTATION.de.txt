R4SLSVC.R4X
===========

R4SLSVC.R4X ist der Serial-Link-Service.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\SerialLinkService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\SerialLinkService\zig-out\R4SLSVC.R4X

Contract:
- R4XStart-Entry: `r4slsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`, `R4NET`
- Service-Name: `R4SLSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\R4SLSVC.R4X`

