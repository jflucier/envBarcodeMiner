You can build a [dicey](https://github.com/gear-genomics/dicey) singularity container (SIF file) using

`singularity build --force --fakeroot envBarcodeMiner.sif envBarcodeMiner.def`

Once you have built the container you can test image using:

`singularity exec --writable-tmpfs -e envBarcodeMiner.mp2.sif dicey --version`

