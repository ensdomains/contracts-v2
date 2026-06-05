#!/usr/bin/env bun

import { Command } from "commander";
import { appendFileSync, writeFileSync } from "node:fs";
import { bold, cyan, dim, Logger } from "./logger.js";

// Types
interface ENSRegistration {
	id: string;
	labelName: string | null;
	registrant: {
		id: string | null;
	} | null;
	expiryDate: string | null;
	registrationDate: string | null;
	domain: {
		id: string | null;
		name: string | null;
		labelhash: string | null;
		parent: {
			id: string | null;
		} | null;
	} | null;
}

interface GraphQLResponse {
	data: {
		registrations: ENSRegistration[];
	};
	errors?: Array<{ message: string }>;
}

export type ENSRegistrationNetwork = "mainnet" | "sepolia";

interface ExportConfig {
	thegraphApiKey: string;
	network: ENSRegistrationNetwork;
	batchSize: number;
	startIndex: number;
	limit: number | null;
	outputFile: string;
}

// Constants
const SUBGRAPH_IDS: Record<ENSRegistrationNetwork, string> = {
	mainnet: "5XqPmWe6gjyrJtFn9cLy237i4cWw2j9HcUJEXsP5qGtH",
	sepolia: "G1SxZs317YUb9nQX3CC98hDyvxfMJNZH5pPRGpNrtvwN",
};
const GATEWAY_ENDPOINT_TEMPLATE =
	"https://gateway.thegraph.com/api/{API_KEY}/subgraphs/id/{SUBGRAPH_ID}";
const RATE_LIMIT_DELAY_MS = 200;

const logger = new Logger();

function envValue(...names: string[]): string | undefined {
	for (const name of names) {
		const value = process.env[name];
		if (value) return value;
	}
	return undefined;
}

function requireTheGraphApiKey(value: string | undefined): string {
	const apiKey = value ?? envValue("THEGRAPH_API_KEY", "GRAPH_API_KEY");
	if (!apiKey) {
		throw new Error(
			"Missing --thegraph-api-key or THEGRAPH_API_KEY/GRAPH_API_KEY",
		);
	}
	return apiKey;
}

export function parseENSRegistrationNetwork(
	value: string,
): ENSRegistrationNetwork {
	if (value === "mainnet" || value === "sepolia") return value;
	throw new Error(`Unsupported ENS registrations network: ${value}`);
}

export function getGatewayEndpoint(config: {
	thegraphApiKey: string;
	network: ENSRegistrationNetwork;
}): string {
	return GATEWAY_ENDPOINT_TEMPLATE.replace(
		"{API_KEY}",
		config.thegraphApiKey,
	).replace("{SUBGRAPH_ID}", SUBGRAPH_IDS[config.network]);
}

async function fetchRegistrations(
	config: ExportConfig,
	skip: number,
	first: number,
	fetchFn: typeof fetch = fetch,
): Promise<ENSRegistration[]> {
	const endpoint = getGatewayEndpoint(config);

	const query = `
    query GetEthRegistrations($first: Int!, $skip: Int!) {
      registrations(
        first: $first
        skip: $skip
        orderBy: registrationDate
        orderDirection: desc
      ) {
        id
        labelName
        registrant {
          id
        }
        expiryDate
        registrationDate
        domain {
          id
          name
          labelhash
          parent {
            id
          }
        }
      }
    }
  `;

	const response = await fetchFn(endpoint, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
		},
		body: JSON.stringify({
			query,
			variables: { first, skip },
		}),
	});

	if (!response.ok) {
		const errorText = await response.text();
		throw new Error(
			`HTTP error! status: ${response.status}, body: ${errorText}`,
		);
	}

	const result: GraphQLResponse = await response.json();

	if (result.errors) {
		throw new Error(
			`GraphQL error: ${result.errors.map((e) => e.message).join(", ")}`,
		);
	}

	if (!result.data || !result.data.registrations) {
		throw new Error(
			`Invalid response structure from TheGraph: missing data.registrations`,
		);
	}

	return result.data.registrations;
}

function escapeCSV(value: string | null | undefined): string {
	const text = value ?? "";
	if (text.includes(",") || text.includes('"') || text.includes("\n")) {
		return `"${text.replace(/"/g, '""')}"`;
	}
	return text;
}

function registrationToCSVRow(reg: ENSRegistration): string {
	return [
		escapeCSV(reg.domain?.id),
		escapeCSV(reg.domain?.name),
		escapeCSV(reg.domain?.labelhash),
		escapeCSV(reg.registrant?.id),
		"",
		"",
		escapeCSV(reg.labelName),
		escapeCSV(reg.registrationDate),
		escapeCSV(reg.expiryDate),
	].join(",");
}

async function exportRegistrations(config: ExportConfig): Promise<void> {
	let skip = config.startIndex;
	let hasMore = true;
	let totalCount = 0;

	const csvHeader =
		"node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate\n";
	writeFileSync(config.outputFile, csvHeader, "utf-8");

	logger.info(`CSV file created: ${cyan(config.outputFile)}`);
	logger.info(`Fetching registrations from TheGraph Gateway...\n`);

	while (hasMore) {
		try {
			let registrations = await fetchRegistrations(
				config,
				skip,
				config.batchSize,
			);

			if (registrations.length === 0) {
				hasMore = false;
				break;
			}

			if (config.limit && totalCount + registrations.length > config.limit) {
				registrations = registrations.slice(0, config.limit - totalCount);
				hasMore = false;
			}

			const csvRows = registrations.map(registrationToCSVRow).join("\n") + "\n";
			appendFileSync(config.outputFile, csvRows, "utf-8");

			totalCount += registrations.length;
			skip += registrations.length;

			logger.info(
				cyan(`Fetched and wrote ${registrations.length} registrations`) +
					dim(` (total: ${totalCount})`),
			);

			if (config.limit && totalCount >= config.limit) {
				hasMore = false;
				break;
			}

			await new Promise((resolve) => setTimeout(resolve, RATE_LIMIT_DELAY_MS));
		} catch (error) {
			logger.error(`Failed to fetch registrations at skip=${skip}: ${error}`);
			throw error;
		}
	}

	logger.info(`\nTotal registrations exported: ${bold(totalCount.toString())}`);
	logger.success(`Successfully exported to ${config.outputFile}`);
}

export async function main(argv = process.argv): Promise<void> {
	const program = new Command()
		.name("export-registrations")
		.description("Export ENS .eth 2LD registrations from TheGraph to CSV")
		.option(
			"--thegraph-api-key <key>",
			"TheGraph Gateway API key; falls back to THEGRAPH_API_KEY or GRAPH_API_KEY",
		)
		.option(
			"--network <network>",
			"ENS registrations network: mainnet or sepolia",
			"mainnet",
		)
		.option(
			"--batch-size <number>",
			"Number of names to fetch per TheGraph API request",
			"1000",
		)
		.option("--start-index <number>", "Starting index for pagination", "0")
		.option("--limit <number>", "Maximum total number of names to fetch")
		.option(
			"--output <file>",
			"Output CSV file path",
			`csv-data/ens-registrations-${new Date().toISOString().split("T")[0]}.csv`,
		);

	program.parse(argv);
	const opts = program.opts();

	const config: ExportConfig = {
		thegraphApiKey: requireTheGraphApiKey(opts.thegraphApiKey),
		network: parseENSRegistrationNetwork(opts.network),
		batchSize: parseInt(opts.batchSize) || 1000,
		startIndex: parseInt(opts.startIndex) || 0,
		limit: opts.limit ? parseInt(opts.limit) : null,
		outputFile: opts.output,
	};

	try {
		logger.header("ENS Registration Export");
		logger.divider();

		logger.info(`Configuration:`);
		logger.config(
			"TheGraph API Key",
			`${config.thegraphApiKey.substring(0, 8)}...`,
		);
		logger.config("Network", config.network);
		logger.config("Batch Size", config.batchSize);
		logger.config("Start Index", config.startIndex);
		logger.config("Limit", config.limit ?? "none");
		logger.config("Output File", config.outputFile);
		logger.info("");

		await exportRegistrations(config);

		logger.success("\nExport completed successfully!");
	} catch (error) {
		logger.error(`Fatal error: ${error}`);
		console.error(error);
		process.exit(1);
	}
}

if (import.meta.main) {
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});
}
