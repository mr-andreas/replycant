import "@testing-library/jest-dom/vitest";
import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";

// Resets mounted trees between tests so assertions target one component instance.
afterEach(() => {
  cleanup();
});
