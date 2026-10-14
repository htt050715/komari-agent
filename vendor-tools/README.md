# NSSM installer dependency

`nssm-2.24-101-g897c7ad.zip` is the unchanged official NSSM archive, distributed under the public domain terms in its README.

Source: https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip

SHA-256: `99f5045fffbffb745d67fe3a065a953c4a3d9c253b868892d9b685b0ee7d07b8`

The hash was compared with Microsoft's winget manifest:
https://github.com/microsoft/winget-pkgs/blob/master/manifests/n/NSSM/NSSM/2.24-101-g897c7ad/NSSM.NSSM.installer.yaml

Release workflow attaches the ZIP so Windows installers can use the fork's GitHub proxy, GitHub directly, then the official URL. Every downloaded archive must match this fixed SHA-256. Existing functional NSSM installations are reused.
