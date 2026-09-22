# Third-party notices

Original OpenFly Go code is licensed under Apache-2.0 in LICENSE. Third-party
code, SDK binaries and map services retain their own terms.

## DJI SDK and sample code

The DJI SDK binary is subject to the [DJI EULA](https://developer.dji.com/policies/eula/),
not this project's Apache license. DJI's SDK/sample licensing notice is retained
in `LICENSES/DJI-Mobile-SDK-LICENSE.txt`; its sample-code portion uses MIT.
Retain existing third-party headers when modifying or redistributing their code.

DJI's notice identifies dynamically linked FFmpeg libraries under LGPL-2.1.
The license text is in `LICENSES/FFmpeg-LGPL-2.1.txt`; DJI provides its source
and build instructions at [dji-sdk/FFmpeg](https://github.com/dji-sdk/FFmpeg).
A binary release must include the applicable notices and source/relinking
information for the actual libraries shipped, rather than claiming the SDK
or its dependencies are Apache-licensed.

## Other dependencies

- Clipper2 Swift package: Boost Software License 1.0; see
  `LICENSES/Clipper2-Boost-1.0.txt`. The pinned revision is in `project.yml` and
  `DJIVLNiOS.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- DJIWidget: its bundled notice is preserved in `LICENSES/DJIWidget-LICENSE.txt`,
  copied from the installed dependency. CocoaPods versions are in `Podfile.lock`.
- Apple frameworks and platform services retain Apple's applicable terms.

OpenFly Go is not affiliated with or endorsed by DJI. The project license and
these notices do not replace the flight-safety instructions in README.md.
