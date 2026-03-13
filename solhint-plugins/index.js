const ordering = require("./ordering");
const importOrderSeparation = require("./import-order-separation");
const selectorTags = require("./selector-tags");
const natspecTripleSlash = require("./natspec-triple-slash");
const natspec = require("./natspec");
const categoryHeaders = require("./category-headers");

module.exports = [ordering, importOrderSeparation, selectorTags, natspecTripleSlash, natspec, categoryHeaders];
