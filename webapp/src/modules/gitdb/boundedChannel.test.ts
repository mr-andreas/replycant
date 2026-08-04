import { describe, expect, it } from "vitest";
import { BoundedChannel } from "./boundedChannel";

describe("BoundedChannel", () => {
  it("delivers items in FIFO order", async () => {
    const ch = new BoundedChannel<number>(10);
    await ch.send(1);
    await ch.send(2);
    await ch.send(3);
    ch.close();

    const received: number[] = [];
    for await (const item of ch.receive()) {
      received.push(item);
    }
    expect(received).toEqual([1, 2, 3]);
  });

  it("completes receiver when channel is closed and drained", async () => {
    const ch = new BoundedChannel<string>(5);
    await ch.send("a");
    ch.close();

    const received: string[] = [];
    for await (const item of ch.receive()) {
      received.push(item);
    }
    expect(received).toEqual(["a"]);
  });

  it("yields nothing when closed immediately", async () => {
    const ch = new BoundedChannel<number>(5);
    ch.close();

    const received: number[] = [];
    for await (const item of ch.receive()) {
      received.push(item);
    }
    expect(received).toEqual([]);
  });

  it("applies backpressure when buffer is full", async () => {
    const ch = new BoundedChannel<number>(2);
    await ch.send(1);
    await ch.send(2);

    let thirdSendResolved = false;
    const sendPromise = ch.send(3).then(() => { thirdSendResolved = true; });

    await Promise.resolve();
    await Promise.resolve();
    expect(thirdSendResolved).toBe(false);

    const gen = ch.receive();
    const first = await gen.next();
    expect(first.value).toBe(1);

    await sendPromise;
    expect(thirdSendResolved).toBe(true);

    ch.close();
    const rest: number[] = [];
    for await (const item of { [Symbol.asyncIterator]: () => gen }) {
      rest.push(item);
    }
    expect(rest).toEqual([2, 3]);
  });

  it("handles concurrent producer and consumer", async () => {
    const ch = new BoundedChannel<number>(3);
    const count = 100;

    const producer = (async () => {
      for (let i = 0; i < count; i++) {
        await ch.send(i);
      }
      ch.close();
    })();

    const received: number[] = [];
    const consumer = (async () => {
      for await (const item of ch.receive()) {
        received.push(item);
      }
    })();

    await Promise.all([producer, consumer]);
    expect(received).toEqual(Array.from({ length: count }, (_, i) => i));
  });

  it("throws when sending on a closed channel", async () => {
    const ch = new BoundedChannel<number>(5);
    ch.close();
    await expect(ch.send(1)).rejects.toThrow("Cannot send on a closed channel");
  });

  it("rejects capacity less than 1", () => {
    expect(() => new BoundedChannel(0)).toThrow("capacity must be >= 1");
  });

  it("supports multiple items flowing through with capacity 1", async () => {
    const ch = new BoundedChannel<number>(1);

    const producer = (async () => {
      for (let i = 0; i < 5; i++) await ch.send(i);
      ch.close();
    })();

    const received: number[] = [];
    const consumer = (async () => {
      for await (const item of ch.receive()) received.push(item);
    })();

    await Promise.all([producer, consumer]);
    expect(received).toEqual([0, 1, 2, 3, 4]);
  });
});
