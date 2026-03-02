import { type ByteArray, concat, hexToBytes, stringToBytes, toHex } from "viem";
import { dnsEncodeName } from "../../utils/utils.js";

export type RR = {
  name: ByteArray;
  type: number;
  class: number;
  ttl?: number;
  data: ByteArray;
};

export function encodeRRs(rr: RR[]) {
  const v = new Uint8Array(
    rr.reduce((a, x) => a + x.name.length + 10 + x.data.length, 0), // see below
  );
  const dv = new DataView(v.buffer, v.byteOffset, v.byteLength);
  let pos = 0;
  for (const x of rr) {
    v.set(x.name, pos);
    pos += x.name.length;
    dv.setUint16(pos, x.type);
    pos += 2;
    dv.setUint16(pos, x.class);
    pos += 2; // 4
    if (x.ttl) dv.setUint32(pos, x.ttl);
    pos += 4; // 8
    dv.setUint16(pos, x.data.length);
    pos += 2; // 10 => same as above
    v.set(x.data, pos);
    pos += x.data.length;
  }
  return toHex(v);
}

export function makeTXT(name: string, txt: string): RR {
  return {
    name: hexToBytes(dnsEncodeName(name)),
    class: 1, // CLASS_INET
    type: 16, // QTYPE_TXT
    data: encodeTXT(txt),
  };
}

function encodeTXT(txt: string) {
  const m: Uint8Array[] = [];
  for (let v = stringToBytes(txt); v.length; v = v.subarray(255)) {
    const chunk = v.subarray(0, 255);
    m.push(Uint8Array.of(chunk.length), chunk);
  }
  return concat(m);
}
