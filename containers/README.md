You can build a [dicey](https://github.com/gear-genomics/dicey) singularity container (SIF file) using

`singularity build envBarcodeMiner.sif docker://geargenomics/dicey`

Once you have built the container you can test image using:

`singularity exec --writable-tmpfs -e envBarcodeMiner.mp2.sif dicey --version`

If image not working, you an try building image using def file:

`singularity build --force --fakeroot envBarcodeMiner.sif envBarcodeMiner.def`