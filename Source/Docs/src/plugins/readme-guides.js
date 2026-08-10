import { readFileSync } from 'node:fs';

const readmeUrl = new URL('../../../../README.MD', import.meta.url);

function slugify(title) {
	return title
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-|-$/g, '');
}

function titleFromHeading(heading) {
	return heading.replace(/!\[[^\]]*\]\([^)]*\)\s*/g, '').trim();
}

function readmeSections() {
	const readme = readFileSync(readmeUrl, 'utf8');
	const headings = [...readme.matchAll(/^## (.+)$/gm)];

	return headings.map((match, index) => {
		const title = titleFromHeading(match[1]);
		const start = match.index + match[0].length + 1;
		const end = headings[index + 1]?.index ?? readme.length;
		return { id: `guides/${slugify(title)}`, title, body: readme.slice(start, end).trim() };
	});
}

export default function readmeGuidesLoader() {
	return {
		name: 'modulefast-readme-guides-loader',
		async load(context) {
			for (const section of readmeSections()) {
				const data = await context.parseData({
					id: section.id,
					data: { title: section.title },
					filePath: readmeUrl.pathname,
				});
				const rendered = await context.renderMarkdown(section.body, { fileURL: readmeUrl });
				context.store.set({
					id: section.id,
					data,
					body: section.body,
					filePath: 'README.MD',
					digest: context.generateDigest(section.body),
					rendered,
				});
			}
		},
	};
}
