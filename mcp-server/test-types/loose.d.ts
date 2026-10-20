// Type loosening for the test program only (tsconfig.test.json): the tests build
// fake Envs and read JSON bodies without declaring their shapes.
interface Response {
  json<T = any>(): Promise<T>;
}
interface Body {
  json<T = any>(): Promise<T>;
}
