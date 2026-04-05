export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("matchmaking", function () {
      this.route("verification-queue");
    });
  },
};
