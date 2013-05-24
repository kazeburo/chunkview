chunkview.pl - HTTP/1.1 Chunked Transfer Visualizer

## SAMPLE

    % ./chunkview.pl  http://blog.livedoor.jp/staff/
    * Chunk View
    ** Headers
     transfer-encoding: chunked
     content-encoding: gzip
     content-length: 
     server: Plack::Handler::Starlet
    ** chunk table
    .-------------------------------------------------.
    | chunk size | byte | content                     |
    +------------+------+-----------------------------+
    |         10 |   16 | (0)                         |
    |        49a | 1178 | <!DOCTYPE html PUBLI(2896)  |
    |       255a | 9562 | ript'; ga.async = tr(41240) |
    |          0 |    0 |                             |
    '------------+------+-----------------------------'

## HOW TO SETUP/USE

    % carton install
    % carton exec -- ./chunkview.pl [url]


