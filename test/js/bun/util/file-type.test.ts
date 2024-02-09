import { test, expect, describe } from "bun:test";
describe("util file tests", () => {
  test("custom set mime-type respected (#6507)", () => {
    const file = Bun.file("test", {
      type: "text/markdown",
    });
    expect(file.type).toBe("text/markdown");

    const custom_type = Bun.file("test", {
      type: "custom/mimetype",
    });
    expect(custom_type.type).toBe("custom/mimetype");
  });

  test("content type is text/css;charset=utf-8", () => {
    const path = tmpdir() + "/bun.test.file-type.css";
    await Bun.write(path, "a{all:unset;}");

    const file = Bun.file(path);
    expect(file.type).toBe("text/css;charset=utf-8");
  });
});
