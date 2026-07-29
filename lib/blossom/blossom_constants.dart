// Manent uploads AES-GCM ciphertext, which sniffs as application/octet-stream.
// Most public Blossom servers inspect the body and reject anything they cannot
// identify as media, so only servers that accept opaque binary work here.
const List<String> fallbackBlossomServers = [
  'https://nostr.download',
  'https://cdn.hzrd149.com',
];
