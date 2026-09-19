import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

export default class extends Controller {
  static values = {
    ariaLabel: String,
    data: Array,
    type: String,
  };

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.render());
    this.resizeObserver.observe(this.element);
    this.render();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
  }

  render() {
    const data = this.dataValue || [];
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    d3.select(this.element).selectAll("svg").remove();
    if (data.length === 0 || width < 80 || height < 80) return;

    const margin = { top: 16, right: 12, bottom: 42, left: 12 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;
    const maximum =
      d3.max(data, (point) => Math.max(point.income, point.expenses)) || 1;
    const y = d3
      .scaleLinear()
      .domain([0, maximum * 1.1])
      .range([innerHeight, 0]);
    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height])
      .attr("role", "img")
      .attr("aria-label", this.ariaLabelValue);
    const chart = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    if (this.typeValue === "bar") {
      this.renderBars(chart, data, innerWidth, innerHeight, y);
    } else {
      this.renderLines(chart, data, innerWidth, innerHeight, y);
    }
  }

  renderBars(chart, data, width, height, y) {
    const x = d3
      .scaleBand()
      .domain(data.map((point) => point.label))
      .range([0, width])
      .padding(0.28);
    const xSeries = d3
      .scaleBand()
      .domain(["income", "expenses"])
      .range([0, x.bandwidth()])
      .padding(0.14);
    const colors = {
      income: "var(--color-success)",
      expenses: "var(--color-destructive)",
    };

    chart
      .selectAll("g.bar-group")
      .data(data)
      .join("g")
      .attr("transform", (point) => `translate(${x(point.label)},0)`)
      .selectAll("rect")
      .data((point) =>
        ["income", "expenses"].map((series) => ({ point, series })),
      )
      .join("rect")
      .attr("x", ({ series }) => xSeries(series))
      .attr("y", ({ point, series }) => y(point[series]))
      .attr("width", xSeries.bandwidth())
      .attr("height", ({ point, series }) => height - y(point[series]))
      .attr("rx", 3)
      .attr("fill", ({ series }) => colors[series]);

    this.renderLabels(chart, x, height);
  }

  renderLines(chart, data, width, height, y) {
    const x = d3
      .scalePoint()
      .domain(data.map((point) => point.label))
      .range([0, width])
      .padding(0.35);
    const colors = {
      income: "var(--color-success)",
      expenses: "var(--color-destructive)",
    };
    ["income", "expenses"].forEach((series) => {
      chart
        .append("path")
        .datum(data)
        .attr("fill", "none")
        .attr("stroke", colors[series])
        .attr("stroke-width", 2)
        .attr(
          "d",
          d3
            .line()
            .x((point) => x(point.label))
            .y((point) => y(point[series])),
        );
    });

    this.renderLabels(chart, x, height);
  }

  renderLabels(chart, x, height) {
    chart
      .append("g")
      .attr("transform", `translate(0,${height})`)
      .call(d3.axisBottom(x).tickSize(0))
      .call((group) => group.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "11px")
      .attr("transform", "translate(0,8)");
  }
}
